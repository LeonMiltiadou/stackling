import AppKit
import SwiftUI

/// Sits over the card image. Click opens it, drag carries the file into any app,
/// and it reports hover even when the panel isn't the key window.
struct DragSurface: NSViewRepresentable {
    let shot: Shot
    var onClick: () -> Void
    var onDropped: (NSDragOperation) -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragSurfaceView {
        let view = DragSurfaceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSurfaceView, context: Context) {
        view.shot = shot
        view.onClick = onClick
        view.onDropped = onDropped
        view.onHover = onHover
    }
}

final class DragSurfaceView: NSView, NSDraggingSource {
    var shot: Shot?
    var onClick: () -> Void = {}
    var onDropped: (NSDragOperation) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    private var mouseDownEvent: NSEvent?
    private var didDrag = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    private var hoverCheck: Timer?

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    /// Tracking areas can miss the exit when the panel resizes under the mouse,
    /// so while hovered we also poll the pointer position.
    private func setHover(_ on: Bool) {
        hoverCheck?.invalidate()
        hoverCheck = nil
        onHover(on)
        guard on else { return }
        hoverCheck = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inside = self.window.map { w in
                self.bounds.contains(self.convert(w.mouseLocationOutsideOfEventStream, from: nil))
            } ?? false
            if !inside || self.window?.isVisible != true { self.setHover(false) }
        }
    }

    static let recheckHover = Notification.Name("StackshotRecheckHover")
    private var recheckObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverCheck?.invalidate()
            recheckObserver.map(NotificationCenter.default.removeObserver)
            recheckObserver = nil
        } else if recheckObserver == nil {
            // The panel ignores the mouse while faded, so no "entered" event arrives
            // if the pointer was already sitting on the card when it wakes up.
            recheckObserver = NotificationCenter.default.addObserver(
                forName: Self.recheckHover, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let w = self.window, self.hoverCheck == nil else { return }
                if self.bounds.contains(self.convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
                    self.setHover(true)
                }
            }
        }
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !didDrag else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        didDrag = true
        startDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil, !didDrag { onClick() }
        mouseDownEvent = nil
    }

    private func startDrag(with event: NSEvent) {
        guard let shot else { return }
        let item = NSDraggingItem(pasteboardWriter: shot.exportURL() as NSURL)
        let image = shot.thumbnail ?? NSWorkspace.shared.icon(forFile: shot.url.path)
        let maxSide: CGFloat = 200
        let scale = min(maxSide / max(image.size.width, 1), maxSide / max(image.size.height, 1), 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: image
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownEvent = nil
        if !operation.isEmpty { onDropped(operation) }
    }
}

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { if start == nil { onHover(false) } }
    override func cursorUpdate(with event: NSEvent) { (start == nil ? NSCursor.openHand : .closedHand).set() }

    /// Where the panel sits when it's in the corner of the screen under the mouse.
    private func cornerOrigin() -> NSPoint? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? window?.screen else { return nil }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.minX + Layout.screenMargin, y: visible.minY + Layout.screenMargin)
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
        snapped = cornerOrigin().map { hypot(window.frame.minX - $0.x, window.frame.minY - $0.y) < Self.snapDistance } ?? false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let now = NSEvent.mouseLocation
        var origin = NSPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y)
        let corner = cornerOrigin()
        let snap = corner.map { hypot(origin.x - $0.x, origin.y - $0.y) < Self.snapDistance } ?? false
        if snap, let corner { origin = corner }
        if snap != snapped {
            snapped = snap
            if snap { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        // See-through while moving, so you can tell what you're about to cover.
        window.alphaValue = 0.85
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
