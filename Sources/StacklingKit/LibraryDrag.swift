import AppKit
import UniformTypeIdentifiers

/// Other apps get rendered pixels; filing within Stackling keeps the editable original.
@MainActor
enum LibraryDrag {
    static let originalType = NSPasteboard.PasteboardType("io.github.leonmiltiadou.stackling.original-file")
    static let types = [originalType.rawValue, UTType.fileURL.identifier]
    private static var originals: [String: URL] = [:]

    static func begin() { originals.removeAll() }

    static func writer(for source: URL) -> NSPasteboardItem? {
        guard let exported = Export.url(for: source) else { return nil }
        let item = NSPasteboardItem()
        item.setString(exported.absoluteString, forType: .fileURL)
        // A private token keeps the original path out of other apps' pasteboards.
        let token = UUID().uuidString
        originals[token] = source
        item.setString(token, forType: originalType)
        return item
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let type = provider.hasItemConformingToTypeIdentifier(originalType.rawValue)
                ? originalType.rawValue : UTType.fileURL.identifier
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                    }
                }
                guard let string = String(data: data, encoding: .utf8) else { continue }
                if type == originalType.rawValue {
                    if let original = originals[string] { urls.append(original) }
                } else if let url = URL(string: string.trimmingCharacters(in: .controlCharacters)), url.isFileURL {
                    urls.append(url)
                }
            } catch {
                Log.library.error("library.drop-read-failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return urls
    }
}
