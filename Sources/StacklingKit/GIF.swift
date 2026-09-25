import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a screen recording into a looping GIF, small enough to paste into Slack or a GitHub issue.
enum GIFMaker {
    /// Longest side of the GIF, in pixels.
    static let maxSide: CGFloat = 960
    static let shortClipFPS: Double = 12
    /// Long recordings get fewer frames so the file stays shareable.
    static let longClipFPS: Double = 8
    /// Seconds after which a recording counts as long.
    static let longClipThreshold: Double = 30
    /// How far a frame may drift from its requested time, which lets the generator skip exact seeks.
    static let frameTolerance = CMTime(value: 1, timescale: 60)

    /// Frames per second for a recording this long.
    static func fps(forDuration seconds: Double) -> Double {
        seconds > longClipThreshold ? longClipFPS : shortClipFPS
    }

    /// The GIF for a recording, made once and reused until the video changes (after a trim, say).
    @MainActor
    static func cached(for shot: Shot) async throws -> URL {
        let video = shot.url
        let out = AppPaths.exports(for: shot.id).appendingPathComponent(video.deletingPathExtension().lastPathComponent + ".gif")
        if let made = out.modificationDate, let source = video.modificationDate, made >= source {
            Log.recording.debug("gif.cache-hit file=\(out.lastPathComponent, privacy: .public)")
            return out
        }
        Log.recording.info("gif.cache-miss file=\(video.lastPathComponent, privacy: .public)")
        try await make(from: video, to: out)
        return out
    }

    static func make(from video: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        let fps = Self.fps(forDuration: seconds)
        let count = max(1, Int(seconds * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance

        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            Log.recording.error("gif.failed reason=create-destination file=\(out.path, privacy: .public)")
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
        var failedFrames = 0
        var firstFailure: Error?
        for await result in generator.images(for: times) {
            do {
                CGImageDestinationAddImage(destination, try result.image, frame)
            } catch {
                failedFrames += 1
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure {
            Log.recording.error("gif.frames-skipped count=\(failedFrames) of=\(count) error=\(firstFailure.localizedDescription, privacy: .public)")
        }
        guard CGImageDestinationFinalize(destination) else {
            Log.recording.error("gif.failed reason=finalize file=\(out.path, privacy: .public)")
            throw CocoaError(.fileWriteUnknown)
        }
        Log.recording.info("gif.made file=\(out.lastPathComponent, privacy: .public) frames=\(count - failedFrames) fps=\(Int(fps)) seconds=\(seconds, format: .fixed(precision: 1))")
    }
}
