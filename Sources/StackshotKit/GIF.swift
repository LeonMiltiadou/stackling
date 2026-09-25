import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a screen recording into a looping GIF, small enough to paste into Slack or a GitHub issue.
enum GIFMaker {
    static let maxSide: CGFloat = 960

    /// The GIF for a recording, made once and reused until the video changes (after a trim, say).
    @MainActor
    static func cached(for shot: Shot) async throws -> URL {
        let video = shot.url
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.leonmiltiadou.stackshot/exports/\(shot.id.uuidString)", isDirectory: true)
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent + ".gif")
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let made = modified(out), let source = modified(video), made >= source { return out }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await make(from: video, to: out)
        return out
    }

    static func make(from video: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        // Long recordings get fewer frames so the file stays shareable.
        let fps: Double = seconds > 30 ? 8 : 12
        let count = max(1, Int(seconds * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frame = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
            ],
        ] as CFDictionary

        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            if let image = try? result.image { CGImageDestinationAddImage(destination, image, frame) }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
