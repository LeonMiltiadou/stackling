// Renders the app icon: three stacked screenshot cards on a deep blue squircle.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background
    let inset: CGFloat = 100
    let bg = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: bg, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.52, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.30, blue: 0.93, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.42, blue: 1.00, alpha: 1),
    ])!.draw(in: bg, angle: 65)

    // Cards, back to front
    let cardW: CGFloat = 560, cardH: CGFloat = 360
    let cards: [(dx: CGFloat, dy: CGFloat, alpha: CGFloat, scale: CGFloat)] = [
        (0, 150, 0.35, 0.86), (0, 85, 0.6, 0.93), (0, 0, 1, 1),
    ]
    for (i, c) in cards.enumerated() {
        let w = cardW * c.scale, h = cardH * c.scale
        let rect = NSRect(x: (size - w) / 2 + c.dx, y: 250 + c.dy + (cardH - h), width: w, height: h)
        let path = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        NSColor.white.withAlphaComponent(c.alpha).setFill()
        path.fill()
        ctx.restoreGState()

        if i == cards.count - 1 {
            // "Screenshot" inside the front card: a sky and a hill
            ctx.saveGState()
            let inner = rect.insetBy(dx: 26, dy: 26)
            NSBezierPath(roundedRect: inner, xRadius: 24, yRadius: 24).addClip()
            NSGradient(colors: [
                NSColor(calibratedRed: 0.45, green: 0.78, blue: 1.0, alpha: 1),
                NSColor(calibratedRed: 0.75, green: 0.90, blue: 1.0, alpha: 1),
            ])!.draw(in: inner, angle: 90)
            let hill = NSBezierPath()
            hill.move(to: NSPoint(x: inner.minX, y: inner.minY))
            hill.line(to: NSPoint(x: inner.minX, y: inner.minY + 90))
            hill.curve(to: NSPoint(x: inner.maxX, y: inner.minY + 130),
                       controlPoint1: NSPoint(x: inner.minX + 170, y: inner.minY + 200),
                       controlPoint2: NSPoint(x: inner.maxX - 200, y: inner.minY + 40))
            hill.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.48, alpha: 1).setFill()
            hill.fill()
            NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: inner.maxX - 130, y: inner.maxY - 110, width: 70, height: 70)).fill()
            ctx.restoreGState()

            // Crop corners
            NSColor.white.setStroke()
            let corner: CGFloat = 70, o: CGFloat = 26
            let r = rect.insetBy(dx: -o, dy: -o)
            for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                let p = NSBezierPath()
                p.lineWidth = 22
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.move(to: NSPoint(x: x + corner * sx, y: y))
                p.line(to: NSPoint(x: x, y: y))
                p.line(to: NSPoint(x: x, y: y + corner * sy))
                p.stroke()
            }
        }
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
