import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// A window for looking at a recording before you share it: play the video, flip to the GIF
/// to see exactly what you'd paste, trim the ends, then copy either one.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ObjectIdentifier: PreviewWindowController] = [:]

    private let model: PreviewModel

    static func show(_ shot: Shot) {
        if let existing = open[ObjectIdentifier(shot)] {
            NSApp.activate()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PreviewWindowController(shot: shot)
        open[ObjectIdentifier(shot)] = controller
        Log.editor.info("preview.open file=\(shot.url.lastPathComponent, privacy: .public) kind=\(shot.isVideo ? "video" : "gif", privacy: .public)")
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.center()
    }

    private init(shot: Shot) {
        model = PreviewModel(shot: shot)

        // Fit the video's shape, within most of the screen.
        let screen = NSScreen.mainVisibleFrame
        let pixels = shot.pixelSize ?? Self.videoSize(shot.url) ?? CGSize(width: 1280, height: 800)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let natural = CGSize(width: pixels.width / scale, height: pixels.height / scale + PreviewView.barHeight)
        let fit = min(1, screen.width * 0.8 / natural.width, screen.height * 0.8 / natural.height)
        let size = CGSize(width: max(natural.width * fit, 640), height: max(natural.height * fit, 420))

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = shot.url.deletingPathExtension().lastPathComponent
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: PreviewView(model: model) { [weak self] in self?.close() })
        // The window keeps the size worked out above instead of growing to the video's full size.
        host.sizingOptions = []
        window.contentView = host
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func videoSize(_ url: URL) -> CGSize? {
        guard let track = AVURLAsset(url: url).tracks(withMediaType: .video).first else { return nil }
        return track.naturalSize
    }

    func windowWillClose(_ notification: Notification) {
        model.player?.pause()
        Self.open[ObjectIdentifier(model.shot)] = nil
    }
}

// MARK: - Model

@MainActor
final class PreviewModel: ObservableObject {
    enum Mode: Hashable { case video, gif }

    let shot: Shot
    @Published var mode: Mode
    @Published private(set) var player: AVPlayer?
    @Published private(set) var gif: NSImage?
    @Published private(set) var gifInfo: String?
    @Published private(set) var gifFailed = false
    /// A short message shown in place of the file info for a moment.
    @Published private(set) var note: String?
    weak var playerView: AVPlayerView?

    /// Seconds a note stays up.
    private static let noteDuration: TimeInterval = 3

    private var loop: NSObjectProtocol?

    init(shot: Shot) {
        self.shot = shot
        mode = shot.isVideo ? .video : .gif
        if shot.isVideo { loadPlayer() } else { showGIF(shot.url) }
    }

    var videoInfo: String {
        var parts: [String] = []
        if let size = shot.pixelSize { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        if let seconds = shot.duration { parts.append(formatDuration(seconds)) }
        if let bytes = shot.url.formattedFileSize { parts.append(bytes) }
        return parts.joined(separator: "  ·  ")
    }

    func switchTo(_ mode: Mode) {
        self.mode = mode
        if mode == .gif {
            player?.pause()
            makeGIFIfNeeded()
        } else {
            player?.play()
        }
    }

    private func loadPlayer() {
        loop.map(NotificationCenter.default.removeObserver)
        let item = AVPlayerItem(url: shot.url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // Loop, like the GIF will.
        loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        self.player = player
        if mode == .video { player.play() }
    }

    private func makeGIFIfNeeded() {
        guard gif == nil, shot.isVideo else { return }
        gifFailed = false
        Task {
            do {
                showGIF(try await GIFMaker.cached(for: shot))
            } catch {
                Log.editor.error("gif.failed file=\(self.shot.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                gifFailed = true
            }
        }
    }

    private func showGIF(_ url: URL) {
        gif = NSImage(contentsOf: url)
        var parts: [String] = []
        if let rep = gif?.representations.first as? NSBitmapImageRep {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
            let frames = (rep.value(forProperty: .frameCount) as? Int) ?? 0
            if frames > 1 { parts.append("\(frames) frames") }
        }
        if let bytes = url.formattedFileSize { parts.append(bytes) }
        gifInfo = parts.joined(separator: "  ·  ")
    }

    // MARK: Trim

    func trim() {
        guard let view = playerView, view.canBeginTrimming else { return }
        player?.pause()
        view.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if result == .okButton { self.saveTrim() } else { self.player?.play() }
            }
        }
    }

    private func saveTrim() {
        guard let item = player?.currentItem else { return }
        let duration = item.duration
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
        guard start > .zero || end < duration else { player?.play(); return }

        say("Trimming…", sticky: true)
        let original = shot.url
        Log.editor.info("trim start=\(start.seconds, format: .fixed(precision: 2)) end=\(end.seconds, format: .fixed(precision: 2)) of=\(duration.seconds, format: .fixed(precision: 2)) file=\(original.lastPathComponent, privacy: .public)")
        Task {
            do {
                try await VideoTrimmer.trim(original, to: CMTimeRange(start: start, end: end))
                shot.refresh()
                gif = nil
                gifInfo = nil
                loadPlayer()
                say("Trimmed")
            } catch {
                Log.editor.error("trim.failed file=\(original.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                say("Couldn't trim")
                player?.play()
            }
        }
    }

    /// Shows `text` in the bar for a few seconds. A `sticky` note stays until the next one replaces it.
    func say(_ text: String, sticky: Bool = false) {
        note = text
        guard !sticky else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteDuration) { [weak self] in
            if self?.note == text { self?.note = nil }
        }
    }
}

// MARK: - View

struct PreviewView: View {
    static let barHeight: CGFloat = 52

    @ObservedObject var model: PreviewModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                switch model.mode {
                case .video:
                    if let player = model.player {
                        PlayerView(player: player, model: model)
                    }
                case .gif:
                    if let gif = model.gif {
                        AnimatedImage(image: gif).padding(12)
                    } else if model.gifFailed {
                        Label("Couldn't make a GIF", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Making GIF…").foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)

            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if model.shot.isVideo {
                Picker("", selection: Binding(get: { model.mode }, set: { model.switchTo($0) })) {
                    Text("Video").tag(PreviewModel.Mode.video)
                    Text("GIF").tag(PreviewModel.Mode.gif)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("See the video, or the GIF you'd get from it")
            }

            Text(model.note ?? (model.mode == .video ? model.videoInfo : model.gifInfo ?? ""))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if model.mode == .video {
                Button("Trim…") { model.trim() }
                    .help("Cut the start or end off the recording")
                Button("Open in QuickTime") { Actions.openInQuickTime(model.shot) }
            } else if model.shot.isVideo {
                Button("Save GIF") {
                    Actions.saveGIF(model.shot)
                    model.say("GIF saved next to the video and added to the stack")
                }
                .disabled(model.gif == nil)
            }

            Button(model.mode == .video ? "Copy Video" : "Copy GIF") {
                if model.mode == .gif && model.shot.isVideo {
                    Actions.copyGIF(model.shot)
                } else {
                    Actions.copy(model.shot)
                }
                close()
            }
            .keyboardShortcut("c", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.mode == .gif && model.gif == nil)
            .help("Copy and take it off the stack")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(height: Self.barHeight)
        .background(.bar)
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let model: PreviewModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsMagnification = true
        view.player = player
        model.playerView = view
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        model.playerView = view
    }
}

/// NSImageView plays animated GIFs by itself; SwiftUI's Image only shows the first frame.
private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}
