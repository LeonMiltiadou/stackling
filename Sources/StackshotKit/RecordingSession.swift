import AVFoundation
import ScreenCaptureKit

/// How recordings are captured and encoded.
enum RecordingSettings {
    static let framesPerSecond = 60
    /// Frames ScreenCaptureKit may keep in flight before it starts dropping them.
    static let queueDepth = 6
    /// Beyond this, H.264 runs out of room and HEVC takes over.
    static let largestH264Size = CGSize(width: 4096, height: 2304)
    /// Average bits per pixel per second: generous, since screen content is sharp text and edges.
    static let bitsPerPixel = 4
    static let minimumBitRate = 2_000_000
    /// A keyframe at least every two seconds, so scrubbing and trimming stay quick.
    static let keyframeInterval = 120

    /// H.264 plays everywhere (Slack, browsers), but tops out around 4K. HEVC covers bigger displays.
    static func codec(width: Int, height: Int) -> AVVideoCodecType {
        CGFloat(width) > largestH264Size.width || CGFloat(height) > largestH264Size.height ? .hevc : .h264
    }

    static func bitRate(width: Int, height: Int) -> Int {
        max(width * height * bitsPerPixel, minimumBitRate)
    }

    /// Video encoders want even dimensions.
    static func evenPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (Int(points.width * scale) & ~1, Int(points.height * scale) & ~1)
    }
}

/// One recording: frames from ScreenCaptureKit written straight into a .mov.
/// Written to a temporary file first so the stack doesn't pick up a half-written video.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let width: Int
    let height: Int
    let codec: AVVideoCodecType
    var codecName: String { codec == .hevc ? "hevc" : "h264" }

    /// Made right after init, because it reports errors back to this session as its delegate.
    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.leonmiltiadou.stackshot.recording")
    private let url: URL
    private var started = false
    var onStoppedByError: (Error) -> Void = { _ in }

    init(filter: SCContentFilter, sourceRect: CGRect?) throws {
        let points = sourceRect?.size ?? filter.contentRect.size
        (width, height) = RecordingSettings.evenPixelSize(points: points, scale: CGFloat(filter.pointPixelScale))
        codec = RecordingSettings.codec(width: width, height: height)
        url = Self.makeTempRecordingURL()

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = Self.makeVideoInput(width: width, height: height, codec: codec)
        guard writer.canAdd(input) else { throw RecorderError.writerFailed }
        writer.add(input)

        let config = Self.makeStreamConfig(width: width, height: height, sourceRect: sourceRect)
        super.init()
        stream = SCStream(filter: filter, configuration: config, delegate: self)
    }

    private static func makeStreamConfig(width: Int, height: Int, sourceRect: CGRect?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingSettings.framesPerSecond))
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = RecordingSettings.queueDepth
        config.capturesAudio = false
        if #available(macOS 15.0, *) { config.showMouseClicks = true }
        return config
    }

    private static func makeVideoInput(width: Int, height: Int, codec: AVVideoCodecType) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingSettings.bitRate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: RecordingSettings.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: RecordingSettings.keyframeInterval,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static func makeTempRecordingURL() -> URL {
        AppPaths.recordings.appendingPathComponent("\(UUID().uuidString).mov")
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
        try await stream.startCapture()
    }

    /// Stops capturing and closes the file. Returns nil if nothing was recorded.
    func finish() async -> URL? {
        do {
            try await stream.stopCapture()
        } catch {
            // Already stopped (after an error, say) is common and harmless; the file can still be closed.
            Log.recording.notice("stop-capture.failed error=\(error.localizedDescription, privacy: .public)")
        }
        return await withCheckedContinuation { done in
            queue.async { [self] in
                guard started else {
                    Log.recording.notice("finish.no-frames")
                    writer.cancelWriting()
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        Log.recording.debug("temp.remove-failed file=\(self.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    }
                    done.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                // Nothing changing on screen means no new frames, so hold the last one until now.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                writer.finishWriting { [self] in
                    guard writer.status == .completed else {
                        let status = writer.status.rawValue
                        let reason = writer.error?.localizedDescription ?? "none"
                        Log.recording.error("writer.failed status=\(status) error=\(reason, privacy: .public)")
                        done.resume(returning: nil)
                        return
                    }
                    done.resume(returning: url)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, Self.isCompleteFrame(buffer) else { return }
        if !started {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStoppedByError(error)
    }

    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
