import AppKit

/// Drawing shared by the editor canvas and the exporter.
/// Everything assumes a flipped NSGraphicsContext in image-pixel space.
enum MarkupRenderer {
    // The file helpers live in ImageFile; these keep older call sites working.
    static func loadImage(_ url: URL) -> CGImage? { ImageFile.load(url) }
    static func pixelScale(_ url: URL) -> CGFloat { ImageFile.pixelScale(url) }
    static func writePNG(_ image: CGImage, to url: URL, pixelScale: CGFloat) throws {
        try ImageFile.writePNG(image, to: url, pixelScale: pixelScale)
    }

    static func padding(for size: CGSize, _ b: Beautify) -> CGFloat {
        b.enabled ? (max(size.width, size.height) * b.padding).rounded() : 0
    }

    static func corner(for size: CGSize, _ b: Beautify) -> CGFloat {
        max(size.width, size.height) * b.corner
    }

    /// The gradient backdrop and drop shadow behind a beautified image.
    static func drawBeautifyBackdrop(canvas: CGRect, image: CGRect, _ b: Beautify) {
        guard b.enabled else { return }
        b.gradient().draw(in: canvas, angle: -45)
        if b.shadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = max(image.width, image.height) * 0.025
            shadow.shadowOffset = NSSize(width: 0, height: -max(image.width, image.height) * 0.008)
            shadow.set()
            NSColor.black.setFill()
            let r = corner(for: image.size, b)
            NSBezierPath(roundedRect: image, xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func drawBase(_ base: CGImage, in rect: CGRect) {
        NSImage(cgImage: base, size: rect.size).draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    static func draw(_ items: [Annotation], base: CGImage, skipping: UUID? = nil) {
        for item in items where item.id != skipping {
            draw(item, base: base)
        }
    }

    static func draw(_ a: Annotation, base: CGImage) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        if a.tool.castsShadow { applyAnnotationShadow(width: a.width) }

        switch a.tool {
        case .select: break
        case .arrow: drawArrow(a)
        case .rect: drawRectangle(a)
        case .ellipse: drawEllipse(a)
        case .line: drawLine(a)
        case .pen, .highlighter: drawFreehand(a)
        case .text: drawText(a)
        case .counter: drawCounter(a)
        case .redact where a.solid == true: drawSolidBlock(a.rect)
        case .redact: drawPixelated(base: base, rect: a.rect)
        }
    }

    // MARK: Annotations

    /// A soft shadow that scales with the stroke, so marks stand out on any screenshot.
    private static func applyAnnotationShadow(width: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = width * 0.9
        shadow.shadowOffset = NSSize(width: 0, height: -width * 0.3)
        shadow.set()
    }

    private static func drawArrow(_ a: Annotation) {
        let p0 = a.start, p1 = a.end
        let len = hypot(p1.x - p0.x, p1.y - p0.y)
        guard len > 1 else { return }
        let ux = (p1.x - p0.x) / len, uy = (p1.y - p0.y) / len
        let head = min(max(a.width * ArrowHead.lengthPerWidth, ArrowHead.minLength), len * ArrowHead.maxShareOfArrow)
        let baseX = p1.x - ux * head, baseY = p1.y - uy * head
        let halfW = head * ArrowHead.halfWidth
        let notch = head * ArrowHead.notch
        let path = NSBezierPath()
        path.move(to: p1)
        path.line(to: CGPoint(x: baseX - uy * halfW, y: baseY + ux * halfW))
        path.line(to: CGPoint(x: baseX + ux * notch, y: baseY + uy * notch))
        path.line(to: CGPoint(x: baseX + uy * halfW, y: baseY - ux * halfW))
        path.close()
        let overlap = head * ArrowHead.shaftOverlap
        let shaft = NSBezierPath()
        shaft.move(to: p0)
        shaft.line(to: CGPoint(x: baseX + ux * overlap, y: baseY + uy * overlap))
        shaft.lineWidth = a.width
        shaft.lineCapStyle = .round
        a.color.ns.set()
        shaft.stroke()
        path.lineJoinStyle = .round
        path.lineWidth = a.width * 0.5
        path.fill()
        path.stroke()
    }

    private static func drawRectangle(_ a: Annotation) {
        let r = a.width * 1.2
        let path = NSBezierPath(roundedRect: a.rect, xRadius: r, yRadius: r)
        path.lineWidth = a.width
        a.color.ns.setStroke()
        path.stroke()
    }

    private static func drawEllipse(_ a: Annotation) {
        let path = NSBezierPath(ovalIn: a.rect)
        path.lineWidth = a.width
        a.color.ns.setStroke()
        path.stroke()
    }

    private static func drawLine(_ a: Annotation) {
        let path = NSBezierPath()
        path.move(to: a.start)
        path.line(to: a.end)
        path.lineWidth = a.width
        path.lineCapStyle = .round
        a.color.ns.setStroke()
        path.stroke()
    }

    /// Pen and highlighter strokes.
    private static func drawFreehand(_ a: Annotation) {
        let path = smoothPath(a.points)
        if a.tool == .highlighter {
            // Plain alpha rather than multiply, so it still shows on dark screenshots.
            path.lineWidth = a.width * Highlighter.widthMultiplier
            path.lineCapStyle = .square
            a.color.ns.withAlphaComponent(Highlighter.opacity).setStroke()
        } else {
            path.lineWidth = a.width
            a.color.ns.setStroke()
        }
        path.stroke()
    }

    private static func drawText(_ a: Annotation) {
        (a.text as NSString).draw(at: a.start, withAttributes: a.textAttributes)
    }

    /// A filled circle with its number in the middle, in black or white, whichever reads better.
    private static func drawCounter(_ a: Annotation) {
        let r = a.counterRadius
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        a.color.ns.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSShadow().set()
        let label = "\(a.number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r * 1.15, weight: .heavy),
            .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)
    }

    /// Replaces the area with big blocks built from the original pixels, so exported
    /// images don't contain anything readable underneath.
    static func drawSolidBlock(_ rect: CGRect) {
        RGBA.redactFill.ns.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    }

    static func drawPixelated(base: CGImage, rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 2, r.height >= 2, let crop = base.cropping(to: r) else { return }
        let block = max(10, Int(max(r.width, r.height) / 18))
        let w = max(1, Int(r.width) / block), h = max(1, Int(r.height) / block)
        guard let small = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let tiny = small.makeImage() else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: tiny, size: r.size).draw(
            in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]
        )
    }

    static func smoothPath(_ pts: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
        }
        path.line(to: pts[pts.count - 1])
        return path
    }

    // MARK: Export

    /// Flattens the screenshot with its markup into a new image.
    static func render(base: CGImage, markup: Markup) -> CGImage? {
        let size = CGSize(width: base.width, height: base.height)
        let pad = padding(for: size, markup.beautify)
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let cg = bitmap.cgContext
        cg.translateBy(x: 0, y: canvas.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current?.imageInterpolation = .high

        let imageRect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        drawBeautifyBackdrop(canvas: CGRect(origin: .zero, size: canvas), image: imageRect, markup.beautify)
        if markup.beautify.enabled {
            let r = corner(for: size, markup.beautify)
            NSBezierPath(roundedRect: imageRect, xRadius: r, yRadius: r).addClip()
        }
        cg.translateBy(x: pad, y: pad)
        drawBase(base, in: CGRect(origin: .zero, size: size))
        draw(markup.items, base: base)

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// The arrowhead's shape. Lengths are shares of the head's own length unless noted.
private enum ArrowHead {
    /// Head length per pixel of stroke width, so thicker arrows get bigger heads.
    static let lengthPerWidth: CGFloat = 3.6
    /// Shortest head in pixels, so thin arrows still read as arrows.
    static let minLength: CGFloat = 16
    /// Longest head as a share of the whole arrow, so short arrows aren't all head.
    static let maxShareOfArrow: CGFloat = 0.8
    /// Half the head's width at its base.
    static let halfWidth: CGFloat = 0.58
    /// How far the middle of the base is pushed forward, giving the head its swept-back notch.
    static let notch: CGFloat = 0.18
    /// How far the shaft runs into the head, so no gap shows between them.
    static let shaftOverlap: CGFloat = 0.2
}

private enum Highlighter {
    /// A highlighter stroke is much wider than a pen stroke of the same size.
    static let widthMultiplier: CGFloat = 5
    static let opacity: CGFloat = 0.38
}

private extension Tool {
    /// Redactions and highlighter strokes sit flat on the image; everything else gets a shadow.
    var castsShadow: Bool { self != .redact && self != .highlighter }
}
