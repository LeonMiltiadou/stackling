import AppKit

/// Reading and writing the image files the editor and exporter work on.
enum ImageFile {
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            Log.editor.error("image.read-failed file=\(url.lastPathComponent, privacy: .public)")
            return nil
        }
        return image
    }

    /// Pixels per point for a screenshot, read from its DPI (screenshots on Retina are 144 DPI).
    static func pixelScale(_ url: URL) -> CGFloat {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 else { return 2 }
        return max(1, CGFloat(dpi / 72))
    }

    /// Saves as PNG, tagged with the DPI that makes it show at the right size in other apps.
    static func writePNG(_ image: CGImage, to url: URL, pixelScale: CGFloat) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dpi = 72 * pixelScale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
