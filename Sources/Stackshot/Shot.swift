import AppKit
import AVFoundation
import Combine
import QuickLookThumbnailing
import SwiftUI

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
    @Published var toast: String?
    /// Annotations and beautify settings, kept beside the file until you flatten them.
    @Published var markup: Markup?
    private(set) var modified: Date?

    var isVideo: Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
    var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
    /// A plain image: something you can annotate, pin or read text from.
    var isStill: Bool { !isVideo && !isGIF }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    init(url: URL, created: Date = Date()) {
        self.url = url
        self.created = created
        self.markup = Markup.load(for: url)
        refresh()
    }

    var hasMarkup: Bool { !(markup?.isEmpty ?? true) }

    func setMarkup(_ new: Markup) {
        markup = new.isEmpty ? nil : new
        new.save(for: url)
        refresh()
    }

    /// The file to hand to other apps: the original, or a flattened copy if you've annotated it.
    func exportURL() -> URL {
        guard hasMarkup, let markup, let base = MarkupRenderer.loadImage(url),
              let rendered = MarkupRenderer.render(base: base, markup: markup) else { return url }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.leonmiltiadou.stackshot/exports/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        do {
            try MarkupRenderer.writePNG(rendered, to: out, pixelScale: MarkupRenderer.pixelScale(url))
            return out
        } catch {
            return url
        }
    }

    /// Re-reads the file: thumbnail, dimensions, modification date.
    func refresh() {
        modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: w, height: h)
        }
        if isVideo { loadVideoInfo() }
        if hasMarkup, let markup, let base = MarkupRenderer.loadImage(url),
           let rendered = MarkupRenderer.render(base: base, markup: markup) {
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
        let now = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let now, now != modified { refresh() }
    }

    /// Shows a short message over the card.
    func flash(_ message: String, for seconds: Double = 0.9) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.toast == message {
                withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
            }
        }
    }
}

@MainActor
final class ShotStore: ObservableObject {
    static let shared = ShotStore()

    /// Newest first.
    @Published private(set) var shots: [Shot] = []
    @Published var expanded = false
    /// Shrunk down to a little box in the corner after a quiet spell. Click it to open the stack again.
    @Published var minimized = false
    /// Things you dismissed, so you can bring them back from the menu.
    @Published private(set) var recent: [Shot] = []
    /// Set by the panel controller based on the screen it lives on.
    @Published var maxListHeight: CGFloat = 600
    /// Where you dragged the stack to (the panel's bottom-left), or nil for the usual corner.
    @Published var customOrigin: NSPoint?

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    func add(_ url: URL, created: Date = Date()) {
        guard !shots.contains(where: { $0.url == url }) else { return }
        recent.removeAll { $0.url == url }
        let shot = Shot(url: url, created: created)
        withAnimation(spring) {
            shots.insert(shot, at: 0)
            minimized = false
        }
    }

    /// Takes it off the stack. The file stays where it is.
    func dismiss(_ shot: Shot) {
        guard shots.contains(where: { $0 === shot }) else { return }
        withAnimation(spring) {
            shots.removeAll { $0 === shot }
            if shots.count <= 1 { expanded = false }
        }
        shot.toast = nil
        recent.insert(shot, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
    }

    /// Dismisses after a short confirmation message, unless ⌥ is held.
    func finish(_ shot: Shot, message: String) {
        shot.flash(message)
        if NSEvent.modifierFlags.contains(.option) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.dismiss(shot) }
    }

    func trash(_ shot: Shot) {
        NSWorkspace.shared.recycle([shot.url]) { _, _ in }
        try? FileManager.default.removeItem(at: Markup.sidecarURL(for: shot.url))
        withAnimation(spring) {
            shots.removeAll { $0 === shot }
            if shots.count <= 1 { expanded = false }
        }
        recent.removeAll { $0 === shot }
    }

    func setMinimized(_ on: Bool) {
        guard on != minimized else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { minimized = on }
    }

    func clearAll() {
        for shot in shots { shot.toast = nil }
        recent.insert(contentsOf: shots, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        withAnimation(spring) {
            shots.removeAll()
            expanded = false
        }
    }

    func restore(_ shot: Shot) {
        recent.removeAll { $0 === shot }
        guard shot.exists else { return }
        withAnimation(spring) {
            shots.insert(shot, at: 0)
            minimized = false
        }
    }

    func restoreAllRecent() {
        let items = recent.filter(\.exists)
        recent.removeAll()
        withAnimation(spring) {
            shots.insert(contentsOf: items, at: 0)
            minimized = false
        }
    }

    func fileChanged(_ url: URL) {
        shots.first { $0.url == url }?.refreshIfModified()
    }

    /// Drops cards whose file was deleted or moved somewhere else.
    func pruneMissing() {
        let missing = shots.filter { !$0.exists }
        guard !missing.isEmpty else { return }
        withAnimation(spring) {
            shots.removeAll { s in missing.contains { $0 === s } }
            if shots.count <= 1 { expanded = false }
        }
        recent.removeAll { !$0.exists }
    }

    func toggleExpanded() {
        withAnimation(spring) { expanded = shots.count > 1 ? !expanded : false }
    }
}
