import AppKit
import SwiftUI

extension NSView {
    /// Swaps `current` for a tracking area over the whole view that reports enter, exit and cursor
    /// updates even when the panel isn't the key window. Call from `updateTrackingAreas`.
    func replaceHoverTrackingArea(_ current: NSTrackingArea?) -> NSTrackingArea {
        if let current { removeTrackingArea(current) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        return area
    }
}

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

    /// How far the mouse has to move with the button down before a click becomes a drag.
    private static let dragThreshold: CGFloat = 4
    /// The longest side of the picture that follows the pointer while dragging.
    private static let dragPreviewMaxSide: CGFloat = 200
    /// How often to double-check the pointer is still over the card while hovered.
    private static let hoverCheckInterval: TimeInterval = 0.25

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking = replaceHoverTrackingArea(tracking)
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
        hoverCheck = Timer.scheduledTimer(withTimeInterval: Self.hoverCheckInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.pointerIsInside || self.window?.isVisible != true { self.setHover(false) }
        }
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    static let recheckHover = Notification.Name("StacklingRecheckHover")
    private var recheckObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverCheck?.invalidate()
            recheckObserver.map(NotificationCenter.default.removeObserver)
            recheckObserver = nil
        } else if recheckObserver == nil {
            // The panel ignores the mouse while tucked away, so no "entered" event arrives
            // if the pointer was already sitting on the card when it wakes up.
            recheckObserver = NotificationCenter.default.addObserver(
                forName: Self.recheckHover, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.window != nil, self.hoverCheck == nil else { return }
                if self.pointerIsInside { self.setHover(true) }
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
        guard hypot(a.x - b.x, a.y - b.y) > Self.dragThreshold else { return }
        didDrag = true
        startDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil, !didDrag { onClick() }
        mouseDownEvent = nil
    }

    private func startDrag(with event: NSEvent) {
        guard let shot else { return }
        Log.actions.info("drag file=\(shot.url.lastPathComponent, privacy: .public)")
        let item = NSDraggingItem(pasteboardWriter: shot.exportURL() as NSURL)
        let image = shot.thumbnail ?? NSWorkspace.shared.icon(forFile: shot.url.path)
        let maxSide = Self.dragPreviewMaxSide
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
        Log.actions.info("drag.ended operation=\(operation.rawValue) dropped=\(!operation.isEmpty)")
        if !operation.isEmpty { onDropped(operation) }
    }
}
