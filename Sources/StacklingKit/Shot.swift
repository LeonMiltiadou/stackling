import AppKit
import AVFoundation
import Combine
import QuickLookThumbnailing
import SwiftUI

/// A short message over a card, e.g. "Copied" or "Making GIF…".
struct Toast: Equatable {
    enum Kind {
        /// Still going: shows a spinner and stays up until something replaces it.
        case working
        case done
        case failed
    }

    let text: String
    let kind: Kind
}

/// One screenshot (or screen recording) sitting in the stack.
@MainActor
final class Shot: ObservableObject, Identifiable {
    let id = UUID()
    var url: URL
    let created: Date
    @Published var thumbnail: NSImage?
    @Published var pixelSize: CGSize?
    /// Length in seconds, for recordings.
    @Published var duration: Double?
    @Published var toast: Toast?
    /// Annotations and beautify settings, kept beside the file until you flatten them.
    @Published var markup: Markup?
    /// You pressed Keep: clean-up never clears it. Stored on the file itself (see `Usage`).
    @Published private(set) var kept = false
    private(set) var modified: Date?

    /// How long a finished or failed message stays on the card.
    nonisolated static let toastDuration: TimeInterval = 0.9

    var isVideo: Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
    var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
    /// A plain image: something you can annotate, pin or read text from.
    var isStill: Bool { !isVideo && !isGIF }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    init(url: URL, created: Date = Date()) {
        self.url = url
        self.created = created
        self.markup = Markup.load(for: url)
        self.kept = Usage.read(url).keep
        refresh()
    }

    func setKept(_ keep: Bool) {
        kept = keep
        Usage.setKeep(url, keep)
    }

    var hasMarkup: Bool { !(markup?.isEmpty ?? true) }

    func setMarkup(_ new: Markup) {
        markup = new.isEmpty ? nil : new
        new.save(for: url)
        refresh()
    }

    /// The image with its annotations drawn in, or nil if there are none (or the file can't be read).
    func renderedWithMarkup() -> CGImage? {
        guard hasMarkup, let markup, let base = MarkupRenderer.loadImage(url) else { return nil }
        return MarkupRenderer.render(base: base, markup: markup)
    }

    /// The file to hand to other apps: the original, or a flattened copy if you've annotated it.
    func exportURL() -> URL {
        guard hasMarkup else { return url }
        guard let rendered = renderedWithMarkup() else {
            Log.actions.error("export.render-failed file=\(self.url.lastPathComponent, privacy: .public) fallback=original")
            return url
        }
        let out = AppPaths.exports(for: id).appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        do {
            try MarkupRenderer.writePNG(rendered, to: out, pixelScale: MarkupRenderer.pixelScale(url))
            return out
        } catch {
            Log.actions.error("export.write-failed file=\(self.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public) fallback=original")
            return url
        }
    }

    /// Re-reads the file: thumbnail, dimensions, modification date.
    func refresh() {
        modified = url.modificationDate
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: w, height: h)
        }
        if isVideo { loadVideoInfo() }
        if let rendered = renderedWithMarkup() {
            thumbnail = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: Layout.cardW, height: Layout.cardH),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in
                if let image {
                    self.thumbnail = image
                } else if self.thumbnail == nil {
                    self.thumbnail = NSImage(contentsOf: self.url)
                }
            }
        }
    }

    private func loadVideoInfo() {
        let asset = AVURLAsset(url: url)
        Task {
            if let length = try? await asset.load(.duration) { duration = length.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                pixelSize = size
            }
        }
    }

    func refreshIfModified() {
        if let now = url.modificationDate, now != modified { refresh() }
    }

    // MARK: Toasts

    /// Shows a message over the card for `seconds`, then fades it out unless something replaced it.
    func show(_ toast: Toast, for seconds: Double) {
        withAnimation(.easeOut(duration: 0.15)) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.toast == toast {
                withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
            }
        }
    }

    /// Something finished: "Copied", "GIF saved".
    func flashDone(_ text: String) { show(Toast(text: text, kind: .done), for: Self.toastDuration) }

    /// Something went wrong: "Couldn't make a GIF".
    func flashFailed(_ text: String) { show(Toast(text: text, kind: .failed), for: Self.toastDuration) }

    /// Still working. Stays up until a done or failed message replaces it, or `timeout` passes in case nothing does.
    func flashWorking(_ text: String, timeout: TimeInterval) { show(Toast(text: text, kind: .working), for: timeout) }

    /// Shows a short "done" message over the card. Kept for callers that predate `Toast`.
    func flash(_ message: String, for seconds: Double = Shot.toastDuration) {
        show(Toast(text: message, kind: .done), for: seconds)
    }
}
