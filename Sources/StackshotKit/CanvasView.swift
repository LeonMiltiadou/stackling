import AppKit
import Combine

/// The editor's drawing surface: shows the screenshot with its markup and turns mouse and
/// keyboard input into annotations.
final class CanvasView: NSView, NSMenuItemValidation {
    let model: EditorModel
    var onCopy: () -> Void = {}
    var onDone: () -> Void = {}

    /// The text annotation being typed into, and the field floating over it.
    struct TextEdit {
        let id: UUID
        let field: NSTextField
        /// Placed by this click, so an empty result undoes the placement instead of deleting.
        let isNew: Bool
    }

    var textEdit: TextEdit?

    private var bag = Set<AnyCancellable>()
    private var drawingID: UUID?
    private var moving: (id: UUID, last: CGPoint, moved: Bool)?

    /// Sizes in view points, so they feel the same at any zoom.
    private enum Metrics {
        /// How close a click has to be to grab an annotation.
        static let hitTolerance: CGFloat = 6
        /// Gap between the selection outline and the annotation.
        static let selectionOutset: CGFloat = 6
        /// Pen points closer together than this are skipped, which keeps strokes smooth.
        static let minFreehandSpacing: CGFloat = 1.5
        /// Shapes shorter than this when the mouse comes up were a click, not a drag, and are dropped.
        static let minShapeLength: CGFloat = 3
    }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.needsDisplay = true
                    self.window?.invalidateCursorRects(for: self)
                }
            }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var geometry: CanvasGeometry {
        CanvasGeometry(
            imageSize: model.imageSize,
            pad: MarkupRenderer.padding(for: model.imageSize, model.markup.beautify),
            viewSize: bounds.size,
            pixelScale: model.pixelScale
        )
    }

    private func point(_ event: NSEvent) -> CGPoint {
        geometry.toImage(convert(event.locationInWindow, from: nil))
    }

    // Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        let g = geometry
        let b = model.markup.beautify
        let imageRect = CGRect(x: g.pad, y: g.pad, width: g.imageSize.width, height: g.imageSize.height)

        cg.saveGState()
        cg.translateBy(x: g.contentOrigin.x, y: g.contentOrigin.y)
        cg.scaleBy(x: g.scale, y: g.scale)

        if b.enabled {
            MarkupRenderer.drawBeautifyBackdrop(canvas: CGRect(origin: .zero, size: g.contentSize), image: imageRect, b)
            let r = MarkupRenderer.corner(for: g.imageSize, b)
            NSBezierPath(roundedRect: imageRect, xRadius: r, yRadius: r).addClip()
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 14 / g.scale
            shadow.set()
            NSColor.black.setFill()
            imageRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        cg.translateBy(x: g.pad, y: g.pad)
        MarkupRenderer.drawBase(model.base, in: CGRect(origin: .zero, size: g.imageSize))
        MarkupRenderer.draw(model.markup.items, base: model.base, skipping: textEdit?.id)
        cg.restoreGState()

        if let sel = model.selected, sel.id != textEdit?.id {
            let outset = -Metrics.selectionOutset
            let path = NSBezierPath(roundedRect: g.toView(sel.bounds).insetBy(dx: outset, dy: outset), xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        repositionTextField()
    }

    // Mouse

    private func topHit(_ p: CGPoint, only tool: Tool? = nil) -> Annotation? {
        let tolerance = Metrics.hitTolerance / geometry.scale
        return model.markup.items.reversed().first { a in
            (tool == nil || a.tool == tool) && a.hitTest(p, tolerance: tolerance)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if textEdit != nil { commitText() }
        window?.makeFirstResponder(self)
        let p = point(event)

        switch model.tool {
        case .select:
            handleSelectClick(at: p, clickCount: event.clickCount)
        case .text:
            placeText(at: p)
        case .counter:
            placeCounter(at: p)
        default:
            // Drag an existing shape with ⌘ held, whatever tool is active.
            if event.modifierFlags.contains(.command), let hit = topHit(p) {
                beginMoving(hit, from: p)
            } else {
                beginShape(at: p)
            }
        }
    }

    /// Selects what's under the click and gets ready to drag it. Double-clicking text edits it.
    private func handleSelectClick(at p: CGPoint, clickCount: Int) {
        guard let hit = topHit(p) else {
            model.selection = nil
            return
        }
        if clickCount == 2, hit.tool == .text {
            model.selection = hit.id
            beginEditing(hit.id, isNew: false)
        } else {
            beginMoving(hit, from: p)
        }
    }

    /// Edits the text under the click, or starts a new one there.
    private func placeText(at p: CGPoint) {
        if let hit = topHit(p, only: .text) {
            beginEditing(hit.id, isNew: false)
            return
        }
        model.checkpoint()
        let a = Annotation(tool: .text, points: [p], color: model.color, width: model.strokeWidth)
        model.markup.items.append(a)
        beginEditing(a.id, isNew: true)
    }

    private func placeCounter(at p: CGPoint) {
        model.checkpoint()
        model.markup.items.append(Annotation(
            tool: .counter, points: [p], color: model.color, width: model.strokeWidth, number: model.nextCounter()
        ))
    }

    /// Starts a drag-drawn shape or freehand stroke at `p`.
    private func beginShape(at p: CGPoint) {
        model.checkpoint()
        let color = model.tool == .redact ? RGBA.redactFill : model.color
        let a = Annotation(tool: model.tool, points: [p, p], color: color, width: model.strokeWidth)
        drawingID = a.id
        model.markup.items.append(a)
    }

    /// Selects `hit` and lets the drag that follows move it.
    private func beginMoving(_ hit: Annotation, from p: CGPoint) {
        model.selection = hit.id
        moving = (hit.id, p, false)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let i = model.index(of: drawingID) {
            let a = model.markup.items[i]
            if a.tool.isFreehand {
                if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) > Metrics.minFreehandSpacing / geometry.scale {
                    model.markup.items[i].points.append(p)
                }
            } else {
                let end = event.modifierFlags.contains(.shift) ? constrained(from: a.start, to: p, tool: a.tool) : p
                model.markup.items[i].points = [a.start, end]
            }
        } else if var m = moving, let i = model.index(of: m.id) {
            if !m.moved {
                model.checkpoint()
                m.moved = true
            }
            model.markup.items[i].offset(by: CGPoint(x: p.x - m.last.x, y: p.y - m.last.y))
            m.last = p
            moving = m
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let i = model.index(of: drawingID) {
            let a = model.markup.items[i]
            let tiny = a.tool.isFreehand
                ? a.points.count < 2
                : hypot(a.end.x - a.start.x, a.end.y - a.start.y) < Metrics.minShapeLength / geometry.scale
            if tiny { model.dropCheckpoint() }
        }
        drawingID = nil
        moving = nil
    }

    /// Holding ⇧: lines and arrows snap to 45°, everything else becomes a square.
    private func constrained(from s: CGPoint, to p: CGPoint, tool: Tool) -> CGPoint {
        guard tool == .arrow || tool == .line else { return squareConstrained(from: s, to: p) }
        let dx = p.x - s.x, dy = p.y - s.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
    }

    // Keyboard

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            model.deleteSelection()
            return
        case KeyCode.escape:
            if model.selection != nil { model.selection = nil } else { onDone() }
            return
        case KeyCode.returnKey, KeyCode.enter:
            onDone()
            return
        default:
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            if model.selection != nil, let delta = nudge(for: event.keyCode, step: step) {
                model.nudgeSelection(delta)
                return
            }
        }

        guard flags.isDisjoint(with: [.command, .control, .option]) else {
            super.keyDown(with: event)
            return
        }
        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            model.tool = tool
            return
        }
        if let size = StrokeSize(key: key) {
            model.pickSize(size)
            return
        }
        super.keyDown(with: event)
    }

    /// How far an arrow key moves the selection, or nil for any other key.
    private func nudge(for keyCode: UInt16, step: CGFloat) -> CGPoint? {
        switch keyCode {
        case KeyCode.left: CGPoint(x: -step, y: 0)
        case KeyCode.right: CGPoint(x: step, y: 0)
        case KeyCode.down: CGPoint(x: 0, y: step)
        case KeyCode.up: CGPoint(x: 0, y: -step)
        default: nil
        }
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func copy(_ sender: Any?) { onCopy() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(delete(_:)): return model.selection != nil
        default: return true
        }
    }
}
