// Renders the Stackling app icon: a little stack of cards on a violet tile, the front card smiling.
// Drawn on a 96-unit grid (the same one as the brand board's SVG) and scaled to macOS's icon size.
import AppKit

let size: CGFloat = 1024
let inset: CGFloat = 100                  // macOS icons leave this margin around the tile
let unit = (size - inset * 2) / 96        // one grid unit in pixels

func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: inset + x * unit, y: inset + y * unit, width: w * unit, height: h * unit)
}

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// A rounded card, turned by `degrees` around its own centre.
func card(_ rect: NSRect, radius: CGFloat, degrees: CGFloat, fill: NSColor, shadow: Bool = false) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.translateBy(x: -rect.midX, y: -rect.midY)
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: hex(0x241C6B, 0.45).cgColor)
    }
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius * unit, yRadius: radius * unit).fill()
    ctx.restoreGState()
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // The tile, with the soft drop shadow macOS icons have.
    let tile = r(0, 0, 96, 96)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 22 * unit, yRadius: 22 * unit)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [hex(0xA293FF), hex(0x7B6CF6), hex(0x5446CF)])!.draw(in: tile, angle: -55)

    // The stack, back to front.
    card(r(26, 28, 44, 30), radius: 7, degrees: -9, fill: hex(0xFFFFFF, 0.38))
    card(r(25, 33, 46, 32), radius: 7, degrees: 5, fill: hex(0xFFFFFF, 0.62))
    card(r(22, 40, 52, 36), radius: 8, degrees: 0, fill: hex(0xFFF8EC), shadow: true)

    // Its face.
    hex(0x2B2560).setFill()
    NSBezierPath(ovalIn: r(36.4, 53.4, 7.2, 7.2)).fill()
    NSBezierPath(ovalIn: r(52.4, 53.4, 7.2, 7.2)).fill()
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: inset + 42 * unit, y: inset + 64.5 * unit))
    smile.curve(to: NSPoint(x: inset + 54 * unit, y: inset + 64.5 * unit),
                controlPoint1: NSPoint(x: inset + 45 * unit, y: inset + 68.5 * unit),
                controlPoint2: NSPoint(x: inset + 51 * unit, y: inset + 68.5 * unit))
    smile.lineWidth = 2.8 * unit
    smile.lineCapStyle = .round
    hex(0x2B2560).setStroke()
    smile.stroke()

    // The sunny dot from a screenshot's sky.
    hex(0xFFB547).setFill()
    NSBezierPath(ovalIn: r(63, 44, 8, 8)).fill()
    ctx.restoreGState()
    return true
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
