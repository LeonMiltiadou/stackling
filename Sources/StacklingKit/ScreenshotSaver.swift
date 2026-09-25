import AppKit

/// Writes a finished screenshot into the screenshots folder and puts it on the stack.
@MainActor
enum ScreenshotSaver {
    /// The camera shutter macOS plays for its own screenshots.
    static let shutterSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    /// Saves `image` as a PNG named and tagged the way macOS does, plays the shutter and adds it to the stack.
    static func save(_ image: CGImage, pixelScale: CGFloat) throws {
        let url = CaptureFile.newURL(.screenshot, ext: "png")
        try MarkupRenderer.writePNG(image, to: url, pixelScale: pixelScale)
        CaptureFile.markAsCapture(url)
        NSSound(contentsOfFile: shutterSoundPath, byReference: true)?.play()
        Log.capture.info("saved file=\(url.lastPathComponent, privacy: .public) pixels=\(image.width)x\(image.height)")
        ShotStore.shared.addCapture(url)
    }
}

enum ImageEffects {
    /// Room around the window for the shadow to spread into, in points.
    static let shadowPadding: CGFloat = 40
    static let shadowDrop: CGFloat = 12
    static let shadowBlur: CGFloat = 34
    static let shadowOpacity: CGFloat = 0.45

    /// The soft drop shadow macOS puts around window captures.
    static func addWindowShadow(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let pad = Int(shadowPadding * scale)
        let w = image.width + pad * 2, h = image.height + pad * 2
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: -shadowDrop * scale), blur: shadowBlur * scale,
                      color: NSColor.black.withAlphaComponent(shadowOpacity).cgColor)
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
