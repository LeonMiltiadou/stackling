import CryptoKit
import Foundation

/// The one way files leave Stackling. A still with edits (arrows, boxes, hidden secrets) is handed over as a
/// flattened copy with them drawn in, never the untouched original: a black box that only lives beside the
/// file would otherwise leak the secret it covers. Copies are cached per file and redrawn only when the
/// picture or its edits change.
@MainActor
enum Export {
    /// The file to hand to another app for `url`.
    static func url(for url: URL, markup given: Markup? = nil) -> URL? {
        let markup: Markup?
        do {
            markup = try given ?? Markup.read(for: url)
        } catch {
            Log.actions.error("export.edits-unreadable file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let markup, !markup.isEmpty else { return url }
        let out = folder(for: url, providedEdits: given != nil).appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        if given == nil, isFresh(out, for: url) { return out }
        guard let base = MarkupRenderer.loadImage(url), let rendered = MarkupRenderer.render(base: base, markup: markup) else {
            Log.actions.error("export.render-failed file=\(url.lastPathComponent, privacy: .public)")
            return nil
        }
        do {
            try MarkupRenderer.writePNG(rendered, to: out, pixelScale: MarkupRenderer.pixelScale(url))
            return out
        } catch {
            Log.actions.error("export.write-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A batch is shared only when every image can carry its edits.
    static func urls(for urls: [URL]) -> [URL]? {
        var exported: [URL] = []
        for source in urls {
            guard let url = url(for: source) else { return nil }
            exported.append(url)
        }
        return exported
    }

    /// A cached copy is good while it's newer than both the picture and its edits.
    private static func isFresh(_ out: URL, for url: URL) -> Bool {
        guard let made = out.modificationDate else { return false }
        let sources = [url.modificationDate, Markup.sidecarURL(for: url).modificationDate].compactMap { $0 }
        return sources.allSatisfy { $0 <= made }
    }

    /// One folder per original file, so two files with the same name never share a copy.
    private static func folder(for url: URL, providedEdits: Bool) -> URL {
        let digest = Insecure.MD5.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = AppPaths.cache.appendingPathComponent("exports/files/\(digest)\(providedEdits ? "/provided" : "")", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
