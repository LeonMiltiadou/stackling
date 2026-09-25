import AppKit

/// A full-screen window showing one display's frozen picture while you pick.
final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = .overlayOnAllSpaces
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The pixel magnifier's sizes, and where it sits, kept apart from the drawing so it can be tested.
/// All in the overlay's flipped view space (top-left origin, y down).
enum Loupe {
    /// Width and height of the circle, in points.
    static let diameter: CGFloat = 132
    /// Screen pixels across the circle. Odd, so the one under the cursor sits in the middle.
    static let pixelsAcross = 15
    /// Gap between the cursor and the circle.
    static let cursorOffset: CGFloat = 22
    /// Room kept for the coordinates badge when the circle flips above the cursor.
    static let labelSpace: CGFloat = 44
    /// From the circle's bottom edge to the middle of the coordinates badge.
    static let labelGap: CGFloat = 20

    /// Pixels either side of the centre one.
    static var halfPixels: Int { pixelsAcross / 2 }
    /// How big one magnified pixel is.
    static var cellSize: CGFloat { diameter / CGFloat(pixelsAcross) }

    /// Below and to the right of the cursor, flipping to the other side near the right and bottom edges.
    static func frame(near mouse: CGPoint, in bounds: CGSize) -> CGRect {
        var origin = CGPoint(x: mouse.x + cursorOffset, y: mouse.y + cursorOffset)
        if origin.x + diameter > bounds.width { origin.x = mouse.x - cursorOffset - diameter }
        if origin.y + diameter + labelSpace > bounds.height { origin.y = mouse.y - cursorOffset - diameter - labelSpace }
        return CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
    }

    /// The frozen image's pixel under a point in the view.
    static func pixel(under point: CGPoint, pixelsPerPoint: CGFloat) -> (x: Int, y: Int) {
        (Int((point.x * pixelsPerPoint).rounded(.down)), Int((point.y * pixelsPerPoint).rounded(.down)))
    }

    /// The square of source pixels to magnify, centred on `pixel`. May poke past the image's edges.
    static func sourceRect(around pixel: (x: Int, y: Int)) -> CGRect {
        CGRect(x: pixel.x - halfPixels, y: pixel.y - halfPixels, width: pixelsAcross, height: pixelsAcross)
    }
}

/// One screen's overlay: the frozen picture, dimmed, with the selection, window highlight, hints and loupe.
final class CaptureOverlayView: NSView {
    /// Drags smaller than this on either side count as a click.
    private static let minimumSelectionSide: CGFloat = 3
    private static let areaDimming: CGFloat = 0.32
    private static let windowDimming: CGFloat = 0.18
    /// How far up from the bottom of the screen the hint sits.
    private static let hintInset: CGFloat = 60

    private let frozen: FrozenScreen
    private let windows: [(window: PickableWindow, rect: CGRect)]
    private unowned let controller: CaptureController
    private lazy var bitmap = NSBitmapImageRep(cgImage: frozen.image)
    private let frozenImage: NSImage

    var mode: CaptureController.Mode {
        didSet {
            dragStart = nil
            selection = nil
            updateHover()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var spaceHeld = false
    private var lastDrag: CGPoint?
    private var hovered: (window: PickableWindow, rect: CGRect)?

    private var recording: Bool { controller.purpose == .recording }

    /// Pixels in the frozen image per point in this view.
    private var pixelsPerPoint: CGFloat { CGFloat(frozen.image.width) / max(bounds.width, 1) }

    init(frozen: FrozenScreen, windows: [PickableWindow], mode: CaptureController.Mode, controller: CaptureController) {
        self.frozen = frozen
        self.controller = controller
        self.mode = mode
        self.frozenImage = NSImage(cgImage: frozen.image, size: frozen.screen.frame.size)

        // Window frames are global with a top-left origin; this view's space starts at the screen's top-left corner.
        let screenFrame = frozen.screen.frame
        let origin = CGPoint(x: screenFrame.minX, y: screenFrame.maxY).flippedVertically
        let local = CGRect(origin: .zero, size: screenFrame.size)
        self.windows = windows.compactMap { w in
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            return r.intersects(local) ? (w, r.intersection(local)) : nil
        }
        super.init(frame: local)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .window ? .pointingHand : .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        (mode == .window ? NSCursor.pointingHand : NSCursor.crosshair).set()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let dim = NSBezierPath(rect: bounds)
        if let sel = selection, sel.width > 0, sel.height > 0 {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(mode == .window ? Self.windowDimming : Self.areaDimming).setFill()
        dim.fill()

        if mode == .window, let h = hovered {
            drawWindowHighlight(h)
            drawHint(recording
                ? "Click a window to record it  ·  Space for area  ·  Esc to cancel"
                : "Click a window to capture it  ·  ⌥ click for no shadow  ·  Space for area  ·  Esc to cancel")
            return
        }

        if let sel = selection, sel.width > 0 || sel.height > 0 {
            drawSelection(sel)
        } else {
            drawHint(recording
                ? "Drag to record an area  ·  Click to record the whole screen  ·  Space for window  ·  Esc to cancel"
                : "Drag to capture an area  ·  Space for window  ·  Esc to cancel")
        }

        if let m = mouse, !spaceHeld { drawLoupe(at: m) }
    }

    private func drawWindowHighlight(_ h: (window: PickableWindow, rect: CGRect)) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        h.rect.fill()
        let border = NSBezierPath(rect: h.rect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        border.stroke()
        let size = "\(Int(h.rect.width * pixelsPerPoint)) × \(Int(h.rect.height * pixelsPerPoint))"
        drawBadge("\(h.window.app)  ·  \(size)", at: CGPoint(x: h.rect.midX, y: h.rect.midY), centered: true)
    }

    private func drawSelection(_ sel: CGRect) {
        let outline = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        NSColor.white.setStroke()
        outline.stroke()
        let size = "\(Int((sel.width * pixelsPerPoint).rounded())) × \(Int((sel.height * pixelsPerPoint).rounded()))"
        var badgePoint = CGPoint(x: sel.maxX, y: sel.maxY + 10)
        if badgePoint.y > bounds.height - 40 { badgePoint.y = sel.maxY - 34 }
        drawBadge(size, at: badgePoint, alignRight: true)
    }

    private func drawBadge(_ text: String, at p: CGPoint, alignRight: Bool = false, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var rect = CGRect(x: p.x, y: p.y, width: size.width + 16, height: size.height + 8)
        if alignRight { rect.origin.x -= rect.width }
        if centered { rect.origin = CGPoint(x: p.x - rect.width / 2, y: p.y - rect.height / 2) }
        rect.origin.x = min(max(rect.minX, 6), bounds.width - rect.width - 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attrs)
    }

    /// Only on the screen the mouse is on, so the instructions don't repeat across every display.
    private func drawHint(_ text: String) {
        guard frozen.screen == NSScreen.containing(NSEvent.mouseLocation) else { return }
        drawBadge(text, at: CGPoint(x: bounds.midX, y: bounds.height - Self.hintInset), centered: true)
    }

    // MARK: Loupe

    /// Magnified pixels around the cursor, with the exact position and colour under it.
    private func drawLoupe(at mouse: CGPoint) {
        let circle = Loupe.frame(near: mouse, in: bounds.size)
        let pixel = Loupe.pixel(under: mouse, pixelsPerPoint: pixelsPerPoint)
        drawLoupeBackdrop(circle)
        drawMagnifiedPixels(around: pixel, in: circle)
        drawLoupeRing(circle)
        drawBadge(loupeLabel(for: pixel), at: CGPoint(x: circle.midX, y: circle.maxY + Loupe.labelGap), centered: true)
    }

    /// A black disc with a soft shadow, so the loupe stands off whatever is behind it.
    private func drawLoupeBackdrop(_ circle: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 8
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMagnifiedPixels(around pixel: (x: Int, y: Int), in circle: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.black.setFill()
        circle.fill()

        let source = Loupe.sourceRect(around: pixel)
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        guard let crop = frozen.image.cropping(to: source.intersection(imageBounds)) else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        let cell = Loupe.cellSize
        // Keep the cursor pixel centred even at screen edges.
        let dx = CGFloat(max(0, -Int(source.minX))), dy = CGFloat(max(0, -Int(source.minY)))
        let dest = CGRect(x: circle.minX + dx * cell, y: circle.minY + dy * cell,
                          width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell)
        NSImage(cgImage: crop, size: dest.size).draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                                                     hints: [.interpolation: NSImageInterpolation.none.rawValue])
        drawPixelGrid(in: circle)
        drawCentrePixelBox(in: circle)
    }

    private func drawPixelGrid(in circle: CGRect) {
        let cell = Loupe.cellSize
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let grid = NSBezierPath()
        for i in 0...Loupe.pixelsAcross {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: circle.minX + o, y: circle.minY))
            grid.line(to: CGPoint(x: circle.minX + o, y: circle.maxY))
            grid.move(to: CGPoint(x: circle.minX, y: circle.minY + o))
            grid.line(to: CGPoint(x: circle.maxX, y: circle.minY + o))
        }
        grid.lineWidth = 0.5
        grid.stroke()
    }

    private func drawCentrePixelBox(in circle: CGRect) {
        let cell = Loupe.cellSize
        let offset = CGFloat(Loupe.halfPixels) * cell
        let box = NSBezierPath(rect: CGRect(x: circle.minX + offset, y: circle.minY + offset, width: cell, height: cell))
        box.lineWidth = 1.5
        NSColor.white.setStroke()
        box.stroke()
    }

    private func drawLoupeRing(_ circle: CGRect) {
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.stroke()
    }

    /// "812, 344   #1E90FF": the pixel's position, and its colour when it's on the image.
    private func loupeLabel(for pixel: (x: Int, y: Int)) -> String {
        var label = "\(pixel.x), \(pixel.y)"
        if pixel.x >= 0, pixel.y >= 0, pixel.x < bitmap.pixelsWide, pixel.y < bitmap.pixelsHigh,
           let c = bitmap.colorAt(x: pixel.x, y: pixel.y)?.usingColorSpace(.sRGB) {
            label += String(format: "   #%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        return label
    }

    // MARK: Mouse

    private func updateHover() {
        guard mode == .window, let m = mouse else { hovered = nil; return }
        hovered = windows.first { $0.rect.contains(m) }
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if mode == .window {
            updateHover()
            guard let h = hovered else { return }
            controller.finishWindow(h.window, frozen: frozen, pixelRect: pixelRect(h.rect),
                                    withShadow: !event.modifierFlags.contains(.option))
            return
        }
        dragStart = p
        lastDrag = p
        selection = CGRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        guard mode == .area, var start = dragStart else { return }
        if spaceHeld, let last = lastDrag {
            // Space held: move the whole selection instead of resizing it.
            start.x += p.x - last.x
            start.y += p.y - last.y
            dragStart = start
            if let sel = selection { selection = sel.offsetBy(dx: p.x - last.x, dy: p.y - last.y) }
        } else {
            let end = event.modifierFlags.contains(.shift) ? squareConstrained(from: start, to: p) : p
            selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        lastDrag = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let sel = selection?.intersection(bounds) else { return }
        dragStart = nil
        selection = nil
        if sel.width < Self.minimumSelectionSide || sel.height < Self.minimumSelectionSide {
            // A plain click records the whole screen.
            if recording { controller.finishArea(frozen, pixelRect: pixelRect(bounds)); return }
            needsDisplay = true
            return
        }
        controller.finishArea(frozen, pixelRect: pixelRect(sel))
    }

    private func pixelRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * pixelsPerPoint, y: r.minY * pixelsPerPoint, width: r.width * pixelsPerPoint, height: r.height * pixelsPerPoint)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.escape:
            controller.cancel()
        case KeyCode.space:
            if dragStart != nil {
                spaceHeld = true
            } else if !event.isARepeat {
                controller.setMode(mode == .area ? .window : .area)
            }
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == KeyCode.space {
            spaceHeld = false
            needsDisplay = true
        }
    }
}
