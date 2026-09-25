import AppKit
import SwiftUI

/// Moves the whole stack panel while you drag it. Near the corner it snaps into place,
/// and letting go there (or double-clicking) sends the stack back to the corner.
struct MoveGrip: NSViewRepresentable {
    let store: ShotStore
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MoveGripView {
        let view = MoveGripView()
        view.toolTip = "Drag to move the stack. Double-click to put it back in the corner"
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MoveGripView, context: Context) {
        view.store = store
        view.onHover = onHover
    }
}

final class MoveGripView: NSView {
    var store: ShotStore?
    var onHover: (Bool) -> Void = { _ in }
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var snapped = false
    private var tracking: NSTrackingArea?

    private static let snapDistance: CGFloat = 40
    /// See-through while moving, so you can tell what you're about to cover.
    private static let movingAlpha: CGFloat = 0.85

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking = replaceHoverTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { if start == nil { onHover(false) } }
    override func cursorUpdate(with event: NSEvent) { (start == nil ? NSCursor.openHand : .closedHand).set() }

    /// Where the panel sits when it's in the corner of the screen under the mouse.
    private func cornerOrigin() -> NSPoint? {
        guard let screen = NSScreen.containing(NSEvent.mouseLocation) ?? window?.screen else { return nil }
        return Layout.cornerOrigin(in: screen.visibleFrame)
    }

    private func isNearCorner(_ origin: NSPoint, _ corner: NSPoint?) -> Bool {
        corner.map { hypot(origin.x - $0.x, origin.y - $0.y) < Self.snapDistance } ?? false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            start = nil
            store?.customOrigin = nil
            return
        }
        guard let window else { return }
        start = (NSEvent.mouseLocation, window.frame.origin)
        // Already in the corner counts as snapped, so picking it up there doesn't tick.
        snapped = isNearCorner(window.frame.origin, cornerOrigin())
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let now = NSEvent.mouseLocation
        var origin = NSPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y)
        let corner = cornerOrigin()
        let snap = isNearCorner(origin, corner)
        if snap, let corner { origin = corner }
        if snap != snapped {
            snapped = snap
            if snap { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        window.alphaValue = Self.movingAlpha
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil, let window else { return }
        start = nil
        window.alphaValue = 1
        NSCursor.openHand.set()
        store?.customOrigin = snapped ? nil : window.frame.origin
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { onHover(false) }
    }
}
