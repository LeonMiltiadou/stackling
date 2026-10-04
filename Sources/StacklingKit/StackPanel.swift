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

private extension NSPoint {
    func offsetBy(_ d: CGFloat) -> NSPoint { NSPoint(x: x + d, y: y + d) }
}

/// Keeps the panel in the bottom-left corner (or wherever you dragged it) and sized to its content.
@MainActor
final class StackPanelController {
    private var panel = StackPanel()
    private let store: ShotStore
    private var bag = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var pendingResize: DispatchWorkItem?

    // Shrinking: after a quiet spell the stack becomes a little box you click to open again.
    private var lastActivity = Date()
    private var pollTimer: Timer?
    /// Where the pointer was at the last poll, to tell when it's heading for the stack.
    private var lastPointer: NSPoint?

    // Tucking: the stack gets out of the way completely while an editor or preview window is in front,
    // since both want the same bit of screen. A new shot still peeks in briefly so you see it land.
    private var tucked = false
    private var peekUntil = Date.distantPast
    private var previousShotCount = 0

    private static let pollInterval: TimeInterval = 0.15
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

    init(store: ShotStore) {
        self.store = store
        let host = NSHostingView(rootView: StackView(store: store))
        host.sizingOptions = []
        panel.contentView = host

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

    /// Polling rather than tracking areas: it keeps working while the panel is tucked away and ignoring
    /// the mouse. It only runs while the stack is on screen, so an empty stack costs nothing. Scheduled in
    /// the default run loop mode, so it pauses while a menu is open or a card is being dragged.
    private func setPolling(_ on: Bool) {
        guard on != (pollTimer != nil) else { return }
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

    /// The stack's window, if screenshots would otherwise include it. Normally it hides itself from every
    /// capture, so there's nothing to leave out (and ⇧⌘4 can skip looking up what's on screen).
    var windowNumberToExclude: Int? { panel.sharingType == .none ? nil : panel.windowNumber }

    /// Something happened (new shot, action, settings change): restart the idle clock.
    func noteActivity() {
        lastActivity = Date()
    }

    // MARK: Tucking and shrinking

    private func tick() {
        guard panel.isVisible else { return }
        if updateTucked() { return }
        // While tucked behind an editor the idle clock stands still, so the stack comes back full-size,
        // ready to drag the shot you just edited.
        guard !tucked else { return }
        shrinkIfIdle()
    }

    /// Tucks the stack away while an editor or preview is in front, and brings it back after.
    /// Returns true if that changed, so this tick doesn't also shrink it.
    private func updateTucked() -> Bool {
        let tuck = Self.editorInFront && Date() > peekUntil
        guard tuck != tucked else { return false }
        tucked = tuck
        Log.stack.info("\(tuck ? "tucked" : "untucked", privacy: .public)")
        if !tuck { noteActivity() }
        animateTucked(duration: tuck ? Self.tuckDuration : Self.untuckDuration)
        if !tuck { NotificationCenter.default.post(name: DragSurfaceView.recheckHover, object: nil) }
        return true
    }

    private func shrinkIfIdle() {
        let pointer = NSEvent.mouseLocation
        let keepOpen = Self.pointerKeepsOpen(pointer, previous: lastPointer, stack: panel.frame)
        lastPointer = pointer
        if keepOpen { noteActivity() }
        let delay = AppSettings.shrinkDelay
        if delay > 0, !keepOpen, !store.minimized, Date().timeIntervalSince(lastActivity) > delay {
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
        applyFrame(target)
        panel.orderFrontRegardless()
        setPolling(true)
        rescueIfStranded()
    }

    /// A new shot arrived: let it show over an editor for a moment before tucking away again.
    private func notePeekIfGrew(_ count: Int) {
        if count > previousShotCount { peekUntil = Date().addingTimeInterval(Self.peekDuration) }
        previousShotCount = count
    }

    /// Lets the exit animation play, then hides the panel. An empty stack starts again in the corner.
    private func hideWhenEmpty() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
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
        } else if !panel.isVisible || screen == nil {
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
        if panel.isVisible, target.size == panel.frame.size, target.origin != panel.frame.origin {
            // Only the position changed, e.g. going back to the corner: glide there.
            panel.setFrame(target, display: true, animate: true)
        } else if !panel.isVisible || target.height >= panel.frame.height {
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
        guard panel.isVisible, !panel.isOnActiveSpace else { return }
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
}
