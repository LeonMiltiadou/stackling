import AppKit
import ScreenCaptureKit

/// Stackling's own screen recorder: an area of a display, a whole display, or one window.
/// The video lands on the stack when you stop. Stackling's own windows (the stack, the
/// recording bar) never show up in it; pinned screenshots and key caps do.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    enum Target {
        case area(NSScreen, CGRect)   // rect in the screen's points, top-left origin
        case window(CGWindowID)

        /// An area that covers its whole display, which records without cropping or an outline.
        var isWholeScreen: Bool {
            guard case let .area(screen, rect) = self else { return false }
            return rect.size == screen.frame.size
        }

        /// "area", "screen" or "window", for the logs.
        var kind: String {
            switch self {
            case .window: "window"
            case .area: isWholeScreen ? "screen" : "area"
            }
        }
    }

    /// What ScreenCaptureKit should record, and where the recording bar goes.
    struct RecordingSource {
        let filter: SCContentFilter
        /// The part of the display to keep, or nil for all of it.
        let sourceRect: CGRect?
        let screen: NSScreen
    }

    /// When the current recording started, or nil when not recording.
    @Published private(set) var startedAt: Date?
    var isRecording: Bool { startedAt != nil || session != nil }

    private var session: RecordingSession?
    private var bar: RecordingBar?
    private var outline: RecordingOutline?
    private var keystrokes: KeystrokeOverlay?

    func start(_ target: Target) {
        guard session == nil else {
            Log.recording.debug("start.ignored reason=already-recording")
            return
        }
        // Key caps are shareable, unlike the rest of Stackling's chrome, so the recording picks them up.
        if AppSettings.showKeystrokes, case let .area(screen, rect) = target {
            keystrokes = KeystrokeOverlay.start(over: rect.appKitFrame(inTopLeftSpaceOf: screen))
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let source = try makeSource(target, content: content)
                let session = try RecordingSession(filter: source.filter, sourceRect: source.sourceRect)
                session.onStoppedByError = { [weak self] error in
                    Task { @MainActor in
                        Log.recording.error("stopped-by-error error=\(error.localizedDescription, privacy: .public)")
                        self?.stop()
                    }
                }
                self.session = session
                try await session.start()
                guard self.session === session else {
                    Log.recording.notice("start.race reason=stopped-while-starting")
                    _ = await session.finish()
                    return
                }
                startedAt = Date()
                Log.recording.info("start target=\(target.kind, privacy: .public) pixels=\(session.width)x\(session.height) codec=\(session.codecName, privacy: .public)")
                bar = RecordingBar(screen: source.screen)
                if case let .area(screen, rect) = target, !target.isWholeScreen {
                    outline = RecordingOutline(screen: screen, rect: rect)
                }
            } catch {
                session = nil
                keystrokes?.stop()
                keystrokes = nil
                Log.recording.error("start.failed target=\(target.kind, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// Stops and puts the video on the stack. With `discard`, throws it away instead.
    func stop(discard: Bool = false) {
        guard let session else { return }
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        Log.recording.info("stop seconds=\(seconds, format: .fixed(precision: 1)) discarded=\(discard)")
        self.session = nil
        startedAt = nil
        bar?.close()
        bar = nil
        outline?.close()
        outline = nil
        keystrokes?.stop()
        keystrokes = nil
        Task {
            guard let temp = await session.finish() else { return }
            if discard {
                do {
                    try FileManager.default.removeItem(at: temp)
                } catch {
                    Log.recording.error("discard.cleanup-failed error=\(error.localizedDescription, privacy: .public)")
                }
                return
            }
            do {
                let url = try Self.moveIntoPlace(temp)
                Log.recording.info("saved file=\(url.lastPathComponent, privacy: .public) size=\(url.formattedFileSize ?? "?", privacy: .public)")
                ShotStore.shared.addCapture(url)
            } catch {
                Log.recording.error("save.failed error=\(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    private func makeSource(_ target: Target, content: SCShareableContent) throws -> RecordingSource {
        switch target {
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.windowGone }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY).flippedVertically
            let screen = NSScreen.containing(center) ?? NSScreen.main ?? NSScreen.screens[0]
            return RecordingSource(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil, screen: screen)

        case let .area(screen, rect):
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError.displayGone
            }
            // The stack, the recording bar and the outline mark themselves as not shareable, so macOS leaves them
            // out on its own. Everything else is recorded, Stackling's library and editor included.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return RecordingSource(filter: filter, sourceRect: target.isWholeScreen ? nil : rect, screen: screen)
        }
    }

    /// Moves the finished video from the cache into the screenshots folder, named and tagged the way macOS does.
    private static func moveIntoPlace(_ temp: URL) throws -> URL {
        let url = CaptureFile.newURL(.recording, ext: "mov")
        try FileManager.default.moveItem(at: temp, to: url)
        CaptureFile.markAsCapture(url)
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
