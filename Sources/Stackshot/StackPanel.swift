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

    // Fading: the stack drops to a faint ghost after a quiet spell and comes back on hover.
    private var lastActivity = Date()
    private var faded = false
    private var fadeTimer: Timer?

    init(store: ShotStore) {
        self.store = store
        let host = NSHostingView(rootView: StackView(store: store))
        host.sizingOptions = []
        panel.contentView = host

        Publishers.CombineLatest3(store.$shots, store.$expanded, store.$customOrigin)
            .receive(on: RunLoop.main)
            .sink { [weak self] shots, expanded, origin in self?.layout(count: shots.count, expanded: expanded, origin: origin) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.screen = nil
                self.layout(count: self.store.shots.count, expanded: self.store.expanded, origin: self.store.customOrigin)
            }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.rescueIfStranded() }
            .store(in: &bag)

        // Polling rather than tracking areas: it keeps working while faded, when the panel
        // ignores the mouse so clicks fall through to whatever is underneath.
        // Scheduled in the default run loop mode, so it pauses while a menu is open.
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFade() }
        }
    }

    var windowNumber: Int { panel.windowNumber }

    /// Something happened (new shot, action, settings change): show at full strength and restart the clock.
    func poke() {
        lastActivity = Date()
        setFaded(false)
    }

    private func tickFade() {
        guard panel.isVisible else { return }
        let content = panel.frame.insetBy(dx: Layout.pad - 6, dy: Layout.pad - 6)
        let hovering = NSMouseInRect(NSEvent.mouseLocation, content, false)
        if hovering { lastActivity = Date() }
        let delay = Settings.fadeDelay
        setFaded(delay > 0 && !hovering && Date().timeIntervalSince(lastActivity) > delay)
    }

    private func setFaded(_ fade: Bool) {
        guard fade != faded else { return }
        faded = fade
        panel.ignoresMouseEvents = fade
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fade ? 0.8 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = fade ? Settings.fadedOpacity : 1
        }
        if !fade { NotificationCenter.default.post(name: DragSurfaceView.recheckHover, object: nil) }
    }

    private func mouseScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout(count: Int, expanded: Bool, origin: NSPoint?) {
        pending?.cancel()
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

        let height = expanded
            ? Layout.expandedHeight(count, maxList: maxList)
            : Layout.collapsedHeight(count)
        var target = NSRect(
            x: visible.minX + Layout.screenMargin,
            y: visible.minY + Layout.screenMargin,
            width: Layout.panelWidth,
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
