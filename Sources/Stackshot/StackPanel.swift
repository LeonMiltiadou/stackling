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
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        // Keep the stack out of your own full-screen screenshots where the system allows it.
        sharingType = ProcessInfo.processInfo.environment["STACKSHOT_DEBUG"] == nil ? .none : .readOnly
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
    private var pending: DispatchWorkItem?

    // Shrinking: after a quiet spell the stack becomes a little box you click to open again.
    private var lastActivity = Date()
    private var idleTimer: Timer?

    // Tucking: the stack gets out of the way completely while an editor or preview window is in front,
    // since both want the same bit of screen. A new shot still peeks in briefly so you see it land.
    private var tucked = false
    private var peekUntil = Date.distantPast
    private var lastCount = 0

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
                self.screen = nil
                self.layout(count: self.store.shots.count, expanded: self.store.expanded,
                            origin: self.store.customOrigin, minimized: self.store.minimized)
            }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.rescueIfStranded() }
            .store(in: &bag)

        // Polling rather than tracking areas: it keeps working while the panel is tucked away
        // and ignoring the mouse. Scheduled in the default run loop mode, so it pauses while
        // a menu is open or a card is being dragged.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var windowNumber: Int { panel.windowNumber }

    /// Something happened (new shot, action, settings change): restart the idle clock.
    func poke() {
        lastActivity = Date()
    }

    private func tick() {
        guard panel.isVisible else { return }
        let tuck = Self.editorInFront && Date() > peekUntil
        if tuck != tucked {
            tucked = tuck
            if !tuck { lastActivity = Date() }
            apply(duration: tuck ? 0.2 : 0.3)
            if !tuck { NotificationCenter.default.post(name: DragSurfaceView.recheckHover, object: nil) }
            return
        }
        let content = panel.frame.insetBy(dx: Layout.pad - 6, dy: Layout.pad - 6)
        let hovering = NSMouseInRect(NSEvent.mouseLocation, content, false)
        if hovering { lastActivity = Date() }
        let delay = Settings.fadeDelay
        if delay > 0, !hovering, !store.minimized, Date().timeIntervalSince(lastActivity) > delay {
            store.setMinimized(true)
        }
    }

    private func apply(duration: Double) {
        panel.ignoresMouseEvents = tucked
        let alpha: CGFloat = tucked ? 0 : 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alpha
        }
    }

    /// One of Stackshot's own editor or preview windows is what you're looking at.
    private static var editorInFront: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow, key.isVisible else { return false }
        return key.windowController is EditorWindowController || key.windowController is PreviewWindowController
    }

    private func mouseScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout(count: Int, expanded: Bool, origin: NSPoint?, minimized: Bool) {
        pending?.cancel()
        if count > lastCount { peekUntil = Date().addingTimeInterval(2.5) }
        lastCount = count
        poke()

        guard count > 0 else {
            // Let the exit animation play before hiding.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.screen = nil
                // An empty stack starts again in the corner.
                if self.store.customOrigin != nil { self.store.customOrigin = nil }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            return
        }

        if let origin, let moved = NSScreen.screens.first(where: { NSMouseInRect(origin.offsetBy(Layout.pad), $0.frame, false) }) {
            screen = moved
        } else if !panel.isVisible || screen == nil {
            screen = mouseScreen()
        }
        let visible = (screen ?? mouseScreen()).visibleFrame

        let maxList = visible.height - Layout.screenMargin * 2 - Layout.pad * 2 - Layout.headerH - 8
        if store.maxListHeight != maxList { store.maxListHeight = maxList }

        let height = minimized ? Layout.miniH + Layout.pad * 2
            : expanded ? Layout.expandedHeight(count, maxList: maxList)
            : Layout.collapsedHeight(count)
        var target = NSRect(
            x: visible.minX + Layout.screenMargin,
            y: visible.minY + Layout.screenMargin,
            width: minimized ? Layout.miniW + Layout.pad * 2 : Layout.panelWidth,
            height: min(height, visible.height)
        )
        if let origin {
            // Grow upwards from where you left it, but never off the screen.
            target.origin.x = min(max(origin.x, visible.minX - Layout.pad), visible.maxX - target.width + Layout.pad)
            target.origin.y = min(max(origin.y, visible.minY - Layout.pad), visible.maxY - target.height + Layout.pad)
        }

        if panel.isVisible, target.size == panel.frame.size, target.origin != panel.frame.origin {
            // Only the position changed, e.g. going back to the corner: glide there.
            panel.setFrame(target, display: true, animate: true)
        } else if !panel.isVisible || target.height >= panel.frame.height {
            // Grow right away so nothing gets clipped mid-animation.
            panel.setFrame(target, display: true)
        } else {
            // Shrink once the content has finished animating away.
            let work = DispatchWorkItem { [weak self] in self?.panel.setFrame(target, display: true) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        panel.orderFrontRegardless()
        rescueIfStranded()
    }

    /// macOS sometimes pins the panel to a single desktop even though it's set to join all of them,
    /// and from then on it only shows up there. When that happens, swap in a fresh panel.
    private func rescueIfStranded() {
        guard panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("Stack panel was stuck on another desktop, rebuilding it")
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
