import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Stackshot's own screen recorder: an area of a display, a whole display, or one window.
/// The video lands on the stack when you stop. Stackshot's own windows (the stack, the
/// recording bar) never show up in it; pinned screenshots do.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    enum Target {
        case area(NSScreen, CGRect)   // rect in the screen's points, top-left origin
        case window(CGWindowID)
    }

    /// When the current recording started, or nil when not recording.
    @Published private(set) var startedAt: Date?
    var isRecording: Bool { startedAt != nil || session != nil }

    private var session: RecordingSession?
    private var bar: RecordingBar?
    private var outline: RecordingOutline?

    func start(_ target: Target) {
        guard session == nil else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let (filter, sourceRect, screen) = try makeFilter(target, content: content)
                let session = try RecordingSession(filter: filter, sourceRect: sourceRect)
                session.onStoppedByError = { [weak self] error in
                    Task { @MainActor in
                        log.error("Recording stopped: \(error.localizedDescription, privacy: .public)")
                        self?.stop()
                    }
                }
                self.session = session
                try await session.start()
                // Stopped while it was still starting up.
                guard self.session === session else { _ = await session.finish(); return }
                startedAt = Date()
                bar = RecordingBar(screen: screen)
                if case let .area(screen, rect) = target, rect.size != screen.frame.size {
                    outline = RecordingOutline(screen: screen, rect: rect)
                }
            } catch {
                session = nil
                log.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// Stops and puts the video on the stack. With `discard`, throws it away instead.
    func stop(discard: Bool = false) {
        guard let session else { return }
        self.session = nil
        startedAt = nil
        bar?.close()
        bar = nil
        outline?.close()
        outline = nil
        Task {
            guard let temp = await session.finish(), !discard else { return }
            do {
                let url = try Self.moveIntoPlace(temp)
                ShotStore.shared.add(url)
            } catch {
                log.error("Couldn't save recording: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    private func makeFilter(_ target: Target, content: SCShareableContent) throws -> (SCContentFilter, CGRect?, NSScreen) {
        switch target {
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.windowGone }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitCenter = CGPoint(x: center.x, y: primaryHeight - center.y)
            let screen = NSScreen.screens.first { NSMouseInRect(appKitCenter, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
            return (SCContentFilter(desktopIndependentWindow: window), nil, screen)

        case let .area(screen, rect):
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError.displayGone
            }
            let me = ProcessInfo.processInfo.processIdentifier
            let ours = content.applications.filter { $0.processID == me }
            let pinNumbers = Set(NSApp.windows.compactMap { $0 is PinWindow && $0.isVisible ? CGWindowID($0.windowNumber) : nil })
            let pins = content.windows.filter { pinNumbers.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: pins)
            let whole = rect.size == screen.frame.size
            return (filter, whole ? nil : rect, screen)
        }
    }

    private static func moveIntoPlace(_ temp: URL) throws -> URL {
        let folder = Prefs.screenshotFolder
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Screen Recording \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(stem).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) (\(n)).mov")
            n += 1
        }
        try FileManager.default.moveItem(at: temp, to: url)
        let flag = (try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)) ?? Data()
        _ = flag.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, flag.count, 0, 0) }
        return url
    }
}

enum RecorderError: LocalizedError {
    case windowGone, displayGone, writerFailed

    var errorDescription: String? {
        switch self {
        case .windowGone: "That window closed before recording started"
        case .displayGone: "That display isn't connected any more"
        case .writerFailed: "Couldn't write the video file"
        }
    }
}

// MARK: - Session

/// One recording: frames from ScreenCaptureKit written straight into a .mov.
/// Written to a temporary file first so the stack doesn't pick up a half-written video.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.leonmiltiadou.stackshot.recording")
    private let url: URL
    private var started = false
    var onStoppedByError: (Error) -> Void = { _ in }

    init(filter: SCContentFilter, sourceRect: CGRect?) throws {
        let scale = CGFloat(filter.pointPixelScale)
        let points = sourceRect?.size ?? filter.contentRect.size
        // Video encoders want even dimensions.
        let width = Int(points.width * scale) & ~1
        let height = Int(points.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.capturesAudio = false
        if #available(macOS 15.0, *) { config.showMouseClicks = true }

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.leonmiltiadou.stackshot/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(UUID().uuidString).mov")

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // H.264 plays everywhere (Slack, browsers), but tops out around 4K. HEVC covers bigger displays.
        let big = width > 4096 || height > 2304
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: big ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 4, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerFailed }
        writer.add(input)

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
        try await stream.startCapture()
    }

    /// Stops capturing and closes the file. Returns nil if nothing was recorded.
    func finish() async -> URL? {
        try? await stream.stopCapture()
        return await withCheckedContinuation { done in
            queue.async { [self] in
                guard started else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    done.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                // Nothing changing on screen means no new frames, so hold the last one until now.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                writer.finishWriting { [self] in
                    done.resume(returning: writer.status == .completed ? url : nil)
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

// MARK: - Recording bar

/// The little floating bar while recording: a timer, Stop, and a bin to throw it away.
@MainActor
final class RecordingBar {
    private let panel: NSPanel

    init(screen: NSScreen) {
        let host = NSHostingView(rootView: RecordingBarView(recorder: .shared))
        let size = host.fittingSize
        let visible = screen.visibleFrame
        panel = NSPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

private struct RecordingBarView: View {
    @ObservedObject var recorder: Recorder
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(width: 42, alignment: .leading)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)

            BarButton(help: "Stop and put the video on the stack (⇧⌘7)", tint: .red) {
                recorder.stop()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
            }

            BarButton(help: "Stop and throw this recording away", tint: nil) {
                recorder.stop(discard: true)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
        }
        .frame(height: 40)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    private func elapsed(at now: Date) -> String {
        let s = Int(now.timeIntervalSince(recorder.startedAt ?? now))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A capsule button for the recording bar: filled when tinted, otherwise just a hover highlight.
private struct BarButton<Label: View>: View {
    let help: String
    let tint: Color?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(height: 28)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    private var fill: Color {
        if let tint { return tint.opacity(hover ? 1 : 0.88) }
        return Color.primary.opacity(hover ? 0.1 : 0)
    }
}

// MARK: - Area outline

/// A dashed line just outside the area being recorded, so you know where the edges are.
/// Clicks pass straight through it.
@MainActor
final class RecordingOutline {
    private let window: NSWindow

    init(screen: NSScreen, rect: CGRect) {
        // rect is top-left origin within the screen; windows want bottom-left global.
        let frame = CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width, height: rect.height
        ).insetBy(dx: -3, dy: -3)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none
        window.contentView = OutlineView()
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
