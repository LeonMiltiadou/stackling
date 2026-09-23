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

/// Keeps the panel pinned to the bottom-left corner and sized to its content.
@MainActor
final class StackPanelController {
    private let panel = StackPanel()
    private let store: ShotStore
    private var bag = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var pending: DispatchWorkItem?

    init(store: ShotStore) {
        self.store = store
        let host = NSHostingView(rootView: StackView(store: store))
        host.sizingOptions = []
        panel.contentView = host

        Publishers.CombineLatest(store.$shots, store.$expanded)
            .receive(on: RunLoop.main)
            .sink { [weak self] shots, expanded in self?.layout(count: shots.count, expanded: expanded) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.screen = nil
                self.layout(count: self.store.shots.count, expanded: self.store.expanded)
            }
            .store(in: &bag)
    }

    private func mouseScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout(count: Int, expanded: Bool) {
        pending?.cancel()

        guard count > 0 else {
            // Let the exit animation play before hiding.
            let work = DispatchWorkItem { [weak self] in
                self?.panel.orderOut(nil)
                self?.screen = nil
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            return
        }

        if !panel.isVisible || screen == nil { screen = mouseScreen() }
        let visible = (screen ?? mouseScreen()).visibleFrame

        let maxList = visible.height - Layout.screenMargin * 2 - Layout.pad * 2 - Layout.headerH - 8
        if store.maxListHeight != maxList { store.maxListHeight = maxList }

        let height = expanded
            ? Layout.expandedHeight(count, maxList: maxList)
            : Layout.collapsedHeight(count)
        let target = NSRect(
            x: visible.minX + Layout.screenMargin,
            y: visible.minY + Layout.screenMargin,
            width: Layout.panelWidth,
            height: min(height, visible.height)
        )

        if !panel.isVisible || target.height >= panel.frame.height {
            // Grow right away so nothing gets clipped mid-animation.
            panel.setFrame(target, display: true)
        } else {
            // Shrink once the content has finished animating away.
            let work = DispatchWorkItem { [weak self] in self?.panel.setFrame(target, display: true) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        panel.orderFrontRegardless()
    }
}
