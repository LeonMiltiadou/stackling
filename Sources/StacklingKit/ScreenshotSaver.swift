import AppKit

/// Writes a finished screenshot into the screenshots folder and puts it on the stack.
@MainActor
enum ScreenshotSaver {
    /// The camera shutter macOS plays for its own screenshots.
    static let shutterSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    /// Plays the shutter straight away, writes `image` as a PNG named and tagged the way macOS does, then
    /// adds it to the stack. The PNG is encoded off the main thread: a full Retina screen takes ~90 ms, and
    /// the shutter shouldn't wait for it.
    static func save(_ image: CGImage, pixelScale: CGFloat) {
        NSSound(contentsOfFile: shutterSoundPath, byReference: true)?.play()
        let url = CaptureFile.newURL(.screenshot, ext: "png")
        let started = CFAbsoluteTimeGetCurrent()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageFile.writePNG(image, to: url, pixelScale: pixelScale)
                    CaptureFile.markAsCapture(url)
                }.value
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                Log.capture.info("saved file=\(url.lastPathComponent, privacy: .public) pixels=\(image.width)x\(image.height) ms=\(ms)")
                ShotStore.shared.addCapture(url)
            } catch {
                Log.capture.error("save.failed error=\(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
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
