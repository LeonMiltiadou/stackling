import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that never steals focus from the app you're in.
final class StackPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Keep the stack out of your own full-screen screenshots where the system allows it.
        let sharing: NSWindow.SharingType = ProcessInfo.processInfo.environment["STACKLING_DEBUG"] == nil ? .none : .readOnly
        configureAsOverlay(level: .floating, sharing: sharing)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The stack's SwiftUI host. The panel never becomes key, so like the cards' drag surfaces it takes the
/// first click itself: a click on "N more" or the shrunk box acts straight away rather than being used up.
final class StackHostingView: NSHostingView<StackView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSPoint {
    func offsetBy(_ d: CGFloat) -> NSPoint { NSPoint(x: x + d, y: y + d) }
}

/// What the stack reads from the world: the time, where the pointer is, and how long to wait before
/// shrinking. Live in the app; tests and Stackling Dev script them.
struct StackSenses {
    var now: () -> Date
    var pointer: () -> NSPoint
    var shrinkDelay: () -> TimeInterval
    /// Whether the stack polls on its own timer. Off when a script ticks it by hand.
    var polls: Bool

    static let live = StackSenses(now: Date.init, pointer: { NSEvent.mouseLocation }, shrinkDelay: { AppSettings.shrinkDelay }, polls: true)
}

/// Keeps the panel in the bottom-left corner (or wherever you dragged it) and sized to its content.
@MainActor
final class StackPanelController {
    private var panel = StackPanel()
    private let store: ShotStore
    private let senses: StackSenses
    /// Stackling Dev's stack: built and laid out like the real one, but never ordered in, because window
    /// managers pull any ordered-in window onto the desktop you're using. `showing` stands in for on screen.
    private let hidden: Bool
    private var showing = false
    private var bag = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var pendingResize: DispatchWorkItem?

    // Shrinking: after a quiet spell the stack becomes a little box you click to open again.
    private var lastActivity: Date
    private var pollTimer: Timer?
    /// Where the pointer was at the last poll, to tell when it's heading for the stack.
    private var lastPointer: NSPoint?

    // Tucking: the stack gets out of the way completely while an editor or preview window is in front,
    // since both want the same bit of screen. A new shot still peeks in briefly so you see it land.
    private var tucked = false
    private var peekUntil = Date.distantPast
    private var previousShotCount = 0

    static let pollInterval: TimeInterval = 0.15
    /// Long enough for the cards' exit animation to finish before the panel shrinks or hides.
    private static let exitAnimationDelay: TimeInterval = 0.45
    /// How long a new shot shows over an editor before the stack tucks away again.
    private static let peekDuration: TimeInterval = 2.5
    private static let tuckDuration: TimeInterval = 0.2
    private static let untuckDuration: TimeInterval = 0.3
    /// Hovering counts from a little outside the cards, not from the panel's transparent shadow margin.
    private static let hoverInset: CGFloat = Layout.pad - 6
    /// How much nearer the stack the pointer must get between polls to count as heading for it, so a hand
    /// resting on the mouse doesn't keep the stack open.
    private static let approachStep: CGFloat = 4

    init(store: ShotStore, senses: StackSenses = .live, hidden: Bool = false) {
        self.store = store
        self.senses = senses
        self.hidden = hidden
        lastActivity = senses.now()
        panel.contentView = Self.makeHost(for: store)

        Publishers.CombineLatest4(store.$shots, store.$expanded, store.$customOrigin, store.$minimized)
            .receive(on: RunLoop.main)
            .sink { [weak self] shots, expanded, origin, minimized in
                self?.layout(count: shots.count, expanded: expanded, origin: origin, minimized: minimized)
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Log.stack.notice("screens.changed")
                self.screen = nil
                self.relayout()
            }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.rescueIfStranded() }
            .store(in: &bag)

    }

    /// The panel's content, apart from the panel so tests can lay it out and click-test it with no window.
    static func makeHost(for store: ShotStore) -> NSView {
        let host = StackHostingView(rootView: StackView(store: store))
        host.sizingOptions = []
        return host
    }

    /// Polling rather than tracking areas: it keeps working while the panel is tucked away and ignoring
    /// the mouse. It only runs while the stack is on screen, so an empty stack costs nothing. Scheduled in
    /// the default run loop mode, so it pauses while a menu is open or a card is being dragged.
    private func setPolling(_ on: Bool) {
        guard senses.polls, on != (pollTimer != nil) else { return }
        if on {
            lastPointer = nil
            pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            pollTimer?.tolerance = Self.pollInterval / 3
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        Log.stack.debug("poll running=\(on)")
    }

    var windowNumber: Int { panel.windowNumber }
    var frame: CGRect { panel.frame }
    /// Ordered in. Never true for Stackling Dev's hidden stack.
    var isOnScreen: Bool { panel.isVisible }
    /// On screen, or for the hidden stack, laid out as if it were.
    private var isShowing: Bool { hidden ? showing : panel.isVisible }

    /// The stack's window, if screenshots would otherwise include it. Normally it hides itself from every
    /// capture, so there's nothing to leave out (and ⇧⌘4 can skip looking up what's on screen).
    var windowNumberToExclude: Int? { panel.sharingType == .none ? nil : panel.windowNumber }

    /// Something happened (new shot, action, settings change): restart the idle clock.
    func noteActivity() {
        lastActivity = senses.now()
    }

    // MARK: Tucking and shrinking

    /// One poll. The timer calls it; a script with its own clock calls it by hand.
    func tick() {
        guard isShowing else { return }
        if updateTucked() { return }
        // While tucked behind an editor the idle clock stands still, so the stack comes back full-size,
        // ready to drag the shot you just edited.
        guard !tucked else { return }
        shrinkIfIdle()
    }

    /// Tucks the stack away while an editor or preview is in front, and brings it back after.
    /// Returns true if that changed, so this tick doesn't also shrink it.
    private func updateTucked() -> Bool {
        let tuck = Self.editorInFront && senses.now() > peekUntil
        guard tuck != tucked else { return false }
        tucked = tuck
        Log.stack.info("\(tuck ? "tucked" : "untucked", privacy: .public)")
        ActivityLog.record(.tuck, ["on": tuck])
        if !tuck { noteActivity() }
        animateTucked(duration: tuck ? Self.tuckDuration : Self.untuckDuration)
        if !tuck { NotificationCenter.default.post(name: DragSurfaceView.recheckHover, object: nil) }
        return true
    }

    private func shrinkIfIdle() {
        let pointer = senses.pointer()
        let keepOpen = Self.pointerKeepsOpen(pointer, previous: lastPointer, stack: panel.frame)
        lastPointer = pointer
        if keepOpen { noteActivity() }
        let delay = senses.shrinkDelay()
        let idle = senses.now().timeIntervalSince(lastActivity)
        if delay > 0, !keepOpen, !store.minimized, idle > delay {
            ActivityLog.record(.shrink, ["idle-ms": Int(idle * 1000)])
            store.setMinimized(true, reason: "idle")
        }
    }

    /// The pointer is on the stack, or on its way there since the last look. Both count as using it, so the
    /// stack doesn't shrink away from under you as you reach for "N more" and the click lands on nothing.
    static func pointerKeepsOpen(_ pointer: NSPoint, previous: NSPoint?, stack: CGRect) -> Bool {
        let content = stack.insetBy(dx: hoverInset, dy: hoverInset)
        if NSMouseInRect(pointer, content, false) { return true }
        guard let previous else { return false }
        return distance(from: previous, to: content) - distance(from: pointer, to: content) > approachStep
    }

    private static func distance(from point: NSPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func animateTucked(duration: Double) {
        panel.ignoresMouseEvents = tucked
        let alpha: CGFloat = tucked ? 0 : 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alpha
        }
    }

    /// One of Stackling's own editor or preview windows is what you're looking at.
    private static var editorInFront: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow, key.isVisible else { return false }
        return key.windowController is EditorWindowController || key.windowController is PreviewWindowController
    }

    // MARK: Layout

    /// Lays out from what's in the store now, rather than on the next turn of the run loop.
    func layoutNow() { relayout() }

    /// Lays out again from what's in the store, e.g. after the screens change.
    private func relayout() {
        layout(count: store.shots.count, expanded: store.expanded, origin: store.customOrigin, minimized: store.minimized)
    }

    private func layout(count: Int, expanded: Bool, origin: NSPoint?, minimized: Bool) {
        pendingResize?.cancel()
        notePeekIfGrew(count)
        noteActivity()
        guard count > 0 else { return hideWhenEmpty() }

        let screen = resolveScreen(for: origin)
        let visible = screen.visibleFrame
        let maxList = Layout.maxListHeight(in: visible)
        if store.maxListHeight != maxList { store.maxListHeight = maxList }

        let target = Self.targetFrame(count: count, expanded: expanded, minimized: minimized, origin: origin, visible: visible)
        Log.stack.debug("layout count=\(count) expanded=\(expanded) minimized=\(minimized) screen=\(screen.displayID ?? 0) frame=\(NSStringFromRect(target), privacy: .public)")
        ActivityLog.record(.frame, ["count": count, "expanded": expanded, "minimized": minimized,
                                    "w": Int(target.width), "h": Int(target.height)])
        applyFrame(target)
        if hidden {
            showing = true
        } else {
            panel.orderFrontRegardless()
        }
        setPolling(true)
        rescueIfStranded()
    }

    /// A new shot arrived: let it show over an editor for a moment before tucking away again.
    private func notePeekIfGrew(_ count: Int) {
        if count > previousShotCount { peekUntil = senses.now().addingTimeInterval(Self.peekDuration) }
        previousShotCount = count
    }

    /// Lets the exit animation play, then hides the panel. An empty stack starts again in the corner.
    private func hideWhenEmpty() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.showing = false
            self.setPolling(false)
            self.screen = nil
            if self.store.customOrigin != nil { self.store.customOrigin = nil }
            Log.stack.info("hidden reason=empty")
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitAnimationDelay, execute: work)
    }

    /// The screen the stack lives on: where you dragged it, else it stays put while showing,
    /// else it follows the mouse.
    private func resolveScreen(for origin: NSPoint?) -> NSScreen {
        if let origin, let moved = NSScreen.containing(origin.offsetBy(Layout.pad)) {
            screen = moved
        } else if !isShowing || screen == nil {
            screen = NSScreen.underMouse
        }
        return screen ?? NSScreen.underMouse
    }

    /// Where the panel should be: in the corner of `visible`, or growing upwards from where you left it
    /// but never off the screen.
    static func targetFrame(count: Int, expanded: Bool, minimized: Bool, origin: NSPoint?, visible: CGRect) -> CGRect {
        let size = Layout.panelSize(count: count, expanded: expanded, minimized: minimized, maxList: Layout.maxListHeight(in: visible))
        var target = CGRect(origin: Layout.cornerOrigin(in: visible), size: CGSize(width: size.width, height: min(size.height, visible.height)))
        if let origin {
            target.origin.x = min(max(origin.x, visible.minX - Layout.pad), visible.maxX - target.width + Layout.pad)
            target.origin.y = min(max(origin.y, visible.minY - Layout.pad), visible.maxY - target.height + Layout.pad)
        }
        return target
    }

    private func applyFrame(_ target: CGRect) {
        if isShowing, target.size == panel.frame.size, target.origin != panel.frame.origin {
            // Only the position changed, e.g. going back to the corner: glide there.
            panel.setFrame(target, display: true, animate: !hidden)
        } else if !isShowing || target.height >= panel.frame.height {
            // Grow right away so nothing gets clipped mid-animation.
            panel.setFrame(target, display: true)
        } else {
            // Shrink once the content has finished animating away.
            let work = DispatchWorkItem { [weak self] in self?.panel.setFrame(target, display: true) }
            pendingResize = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitAnimationDelay, execute: work)
        }
    }

    /// macOS sometimes pins the panel to a single desktop even though it's set to join all of them,
    /// and from then on it only shows up there. When that happens, swap in a fresh panel.
    private func rescueIfStranded() {
        guard !hidden, panel.isVisible, !panel.isOnActiveSpace else { return }
        Log.stack.notice("stranded.rescued")
        let old = panel
        let fresh = StackPanel()
        let content = old.contentView
        old.contentView = nil
        old.orderOut(nil)
        fresh.contentView = content
        fresh.setFrame(old.frame, display: false)
        fresh.alphaValue = old.alphaValue
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        panel = fresh
        panel.orderFrontRegardless()
    }

    /// A picture of the live stack, drawn in memory: Stackling Dev's stack is never on screen to capture.
    func snapshot() -> Data? {
        guard let host = panel.contentView, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Aiming

    /// What's under `point`, in the host's own coordinates (top-left origin): the view AppKit's hit-testing
    /// finds, and the stack button laid out there when that view is the SwiftUI host itself, so no card
    /// or other AppKit view sits on top of it.
    static func aim(at point: NSPoint, in host: NSView, store: ShotStore) -> (hit: NSView?, target: StackTarget?) {
        settle(host)
        // hitTest takes the superview's coordinates. A host on its own (a test) has none, so place the point
        // in its frame by hand: the host is flipped, its frame isn't.
        let frame = host.frame
        let inSuperview = host.superview.map { host.convert(point, to: $0) }
            ?? NSPoint(x: frame.minX + point.x, y: host.isFlipped ? frame.maxY - point.y : frame.minY + point.y)
        let hit = host.hitTest(inSuperview)
        guard let hit, hit === host else { return (hit, nil) }
        return (hit, StackTarget.allCases.first { store.targetFrames[$0]?.contains(point) == true })
    }

    /// Brings the SwiftUI content up to date with the store before aiming. A window on screen does this
    /// on every frame; a hidden one, or a script that doesn't let the run loop wait, may not have yet.
    private static func settle(_ host: NSView) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    /// Where a stack button is on screen, if the stack is showing it.
    func screenPoint(of target: StackTarget) -> NSPoint? {
        guard isShowing, let host = panel.contentView else { return nil }
        Self.settle(host)
        guard let frame = store.targetFrames[target] else { return nil }
        return panel.convertPoint(toScreen: host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
    }

    /// Stackling Dev's click at a point on screen. Not a real mouse event: macOS delivers none to a window
    /// that was never shown, and SwiftUI ignores one handed to its view. So it hit-tests the live panel the
    /// way a click would (AppKit down to the SwiftUI host, then where the buttons are laid out) and, when a
    /// stack button is there, presses it with the same call the button makes. Cards are never pressed.
    @discardableResult
    func click(atScreen point: NSPoint) -> (hit: NSView?, target: StackTarget?) {
        var aimed: (hit: NSView?, target: StackTarget?) = (nil, nil)
        if isShowing, !panel.ignoresMouseEvents, panel.frame.contains(point), let host = panel.contentView {
            aimed = Self.aim(at: host.convert(panel.convertPoint(fromScreen: point), from: nil), in: host, store: store)
        }
        let hit = aimed.hit.map { String(describing: type(of: $0)) } ?? "none"
        Log.stack.info("panel.click hit=\(hit, privacy: .public) target=\(aimed.target?.rawValue ?? "none", privacy: .public)")
        ActivityLog.record(.panelClick, ["hit": hit, "target": aimed.target?.rawValue ?? "none"])
        aimed.target?.press(store)
        return aimed
    }
}
