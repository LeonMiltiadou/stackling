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
        try write(image, to: url, type: "public.png" as CFString, pixelScale: pixelScale)
    }

    /// Flattening keeps the file's format and replaces it only after encoding succeeds.
    static func overwrite(_ image: CGImage, at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw CocoaError(.fileReadCorruptFile) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        defer {
            if FileManager.default.fileExists(atPath: temp.path) {
                do { try FileManager.default.removeItem(at: temp) }
                catch { Log.editor.error("image.temp-cleanup-failed error=\(error.localizedDescription, privacy: .public)") }
            }
        }
        try write(image, to: temp, type: type, pixelScale: pixelScale(url))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private static func write(_ image: CGImage, to url: URL, type: CFString, pixelScale: CGFloat) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dpi = 72 * pixelScale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                                kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
