import AppKit

// MARK: - Model

struct RGBA: Codable, Equatable, Hashable {
    var r, g, b, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let palette: [RGBA] = [
        RGBA(1.00, 0.23, 0.19), // red
        RGBA(1.00, 0.58, 0.00), // orange
        RGBA(1.00, 0.80, 0.00), // yellow
        RGBA(0.20, 0.78, 0.35), // green
        RGBA(0.00, 0.48, 1.00), // blue
        RGBA(0.69, 0.32, 0.87), // purple
        RGBA(0.10, 0.10, 0.10), // black
        RGBA(1.00, 1.00, 1.00), // white
    ]
}

enum Tool: String, Codable, CaseIterable, Identifiable {
    case select, arrow, rect, ellipse, line, pen, text, counter, highlighter, redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .pen: "Pen"
        case .text: "Text"
        case .counter: "Counter"
        case .highlighter: "Highlighter"
        case .redact: "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .text: "textformat"
        case .counter: "1.circle"
        case .highlighter: "highlighter"
        case .redact: "eye.slash"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rect: "r"
        case .ellipse: "o"
        case .line: "l"
        case .pen: "p"
        case .text: "t"
        case .counter: "n"
        case .highlighter: "h"
        case .redact: "x"
        }
    }

    /// Tools that make a shape from a drag between two points.
    var isTwoPoint: Bool { [.arrow, .rect, .ellipse, .line, .redact].contains(self) }
    var isFreehand: Bool { self == .pen || self == .highlighter }
}

/// One annotation. All coordinates are image pixels, origin top-left.
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: Tool
    var points: [CGPoint]
    var color: RGBA
    var width: CGFloat
    var text: String = ""
    var number: Int = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var fontSize: CGFloat { width * 5 + 8 }
    var counterRadius: CGFloat { width * 2.4 + 10 }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color.ns]
    }

    /// Area used for hit-testing and the selection outline.
    var bounds: CGRect {
        switch tool {
        case .text:
            let size = (text.isEmpty ? " " : text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: start, size: size)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return rect
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= max(width, tolerance)
        case .pen, .highlighter:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= max(width, tolerance) }
        case .rect, .ellipse:
            // Hollow shapes: grab near the outline, not the middle, so you can draw inside them.
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    mutating func offset(by d: CGPoint) {
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
    }
}

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

struct Beautify: Codable, Equatable {
    var enabled = false
    var background = 0
    var padding: Double = 0.08   // fraction of the image's longer side
    var corner: Double = 0.015   // fraction of the image's longer side
    var shadow = true

    static let backgrounds: [(name: String, colors: [NSColor])] = [
        ("Indigo", [NSColor(srgbRed: 0.27, green: 0.30, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.62, green: 0.40, blue: 1.0, alpha: 1)]),
        ("Sunset", [NSColor(srgbRed: 1.0, green: 0.45, blue: 0.35, alpha: 1), NSColor(srgbRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)]),
        ("Ocean", [NSColor(srgbRed: 0.05, green: 0.55, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.30, green: 0.85, blue: 0.85, alpha: 1)]),
        ("Mint", [NSColor(srgbRed: 0.35, green: 0.80, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.75, green: 0.95, blue: 0.60, alpha: 1)]),
        ("Candy", [NSColor(srgbRed: 0.95, green: 0.35, blue: 0.65, alpha: 1), NSColor(srgbRed: 0.55, green: 0.40, blue: 0.95, alpha: 1)]),
        ("Graphite", [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.34, green: 0.36, blue: 0.42, alpha: 1)]),
        ("Paper", [NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1)]),
    ]

    func gradient() -> NSGradient {
        let colors = Beautify.backgrounds[min(max(background, 0), Beautify.backgrounds.count - 1)].colors
        return NSGradient(colors: colors)!
    }
}

/// Everything you added to a screenshot. Kept in a hidden file next to the image,
/// so the original stays untouched until you choose to flatten it.
struct Markup: Codable, Equatable {
    var items: [Annotation] = []
    var beautify = Beautify()

    var isEmpty: Bool { items.isEmpty && !beautify.enabled }

    static func sidecarURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).stackshot")
    }

    static func load(for url: URL) -> Markup? {
        guard let data = try? Data(contentsOf: sidecarURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(Markup.self, from: data)
    }

    func save(for url: URL) {
        let sidecar = Markup.sidecarURL(for: url)
        if isEmpty {
            try? FileManager.default.removeItem(at: sidecar)
        } else if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: sidecar, options: .atomic)
        }
    }
}

// MARK: - Drawing

/// Drawing shared by the editor canvas and the exporter.
/// Everything assumes a flipped NSGraphicsContext in image-pixel space.
enum MarkupRenderer {
    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Pixels per point for a screenshot, read from its DPI (screenshots on Retina are 144 DPI).
    static func pixelScale(_ url: URL) -> CGFloat {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 else { return 2 }
        return max(1, CGFloat(dpi / 72))
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

        let color = a.color.ns
        if a.tool != .redact && a.tool != .highlighter {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = a.width * 0.9
            shadow.shadowOffset = NSSize(width: 0, height: -a.width * 0.3)
            shadow.set()
        }

        switch a.tool {
        case .select:
            break

        case .arrow:
            let p0 = a.start, p1 = a.end
            let len = hypot(p1.x - p0.x, p1.y - p0.y)
            guard len > 1 else { return }
            let ux = (p1.x - p0.x) / len, uy = (p1.y - p0.y) / len
            let head = min(max(a.width * 3.6, 16), len * 0.8)
            let baseX = p1.x - ux * head, baseY = p1.y - uy * head
            let halfW = head * 0.58
            let path = NSBezierPath()
            path.move(to: p1)
            path.line(to: CGPoint(x: baseX - uy * halfW, y: baseY + ux * halfW))
            path.line(to: CGPoint(x: baseX + ux * head * 0.18, y: baseY + uy * head * 0.18))
            path.line(to: CGPoint(x: baseX + uy * halfW, y: baseY - ux * halfW))
            path.close()
            let shaft = NSBezierPath()
            shaft.move(to: p0)
            shaft.line(to: CGPoint(x: baseX + ux * head * 0.2, y: baseY + uy * head * 0.2))
            shaft.lineWidth = a.width
            shaft.lineCapStyle = .round
            color.set()
            shaft.stroke()
            path.lineJoinStyle = .round
            path.lineWidth = a.width * 0.5
            path.fill()
            path.stroke()

        case .rect:
            let r = a.width * 1.2
            let path = NSBezierPath(roundedRect: a.rect, xRadius: r, yRadius: r)
            path.lineWidth = a.width
            color.setStroke()
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: a.rect)
            path.lineWidth = a.width
            color.setStroke()
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: a.start)
            path.line(to: a.end)
            path.lineWidth = a.width
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()

        case .pen:
            let path = smoothPath(a.points)
            path.lineWidth = a.width
            color.setStroke()
            path.stroke()

        case .highlighter:
            // Plain alpha rather than multiply, so it still shows on dark screenshots.
            let path = smoothPath(a.points)
            path.lineWidth = a.width * 5
            path.lineCapStyle = .square
            color.withAlphaComponent(0.38).setStroke()
            path.stroke()

        case .text:
            (a.text as NSString).draw(at: a.start, withAttributes: a.textAttributes)

        case .counter:
            let r = a.counterRadius
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSShadow().set()
            let textColor: NSColor = a.color.r + a.color.g + a.color.b > 2.4 ? .black : .white
            let label = "\(a.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .heavy),
                .foregroundColor: textColor,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)

        case .redact:
            drawPixelated(base: base, rect: a.rect)
        }
    }

    /// Replaces the area with big blocks built from the original pixels, so exported
    /// images don't contain anything readable underneath.
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

    static func writePNG(_ image: CGImage, to url: URL, pixelScale: CGFloat) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dpi = 72 * pixelScale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
