import AppKit

/// Naming and tagging capture files, and where Stackshot keeps its own working files.
enum CaptureFile {
    enum Kind: String {
        case screenshot = "Screenshot"
        case recording = "Screen Recording"
    }

    /// The same names macOS uses: "Screenshot 2026-09-25 at 11.52.22.png", made unique if needed.
    static func newURL(_ kind: Kind, ext: String, in folder: URL = ScreenshotPrefs.screenshotFolder, at date: Date = Date()) -> URL {
        freeURL(for: "\(kind.rawValue) \(stampFormatter.string(from: date)).\(ext)", in: folder)
    }

    /// `name` in `folder`, or "name (2).ext", "name (3).ext"… if that's taken.
    static func freeURL(for name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    // MARK: Screen capture tag

    /// Spotlight's "this is a screenshot" flag, which macOS sets on its own captures.
    static let tagName = "com.apple.metadata:kMDItemIsScreenCapture"
    static let namePrefixes = ["Screenshot", "Screen Recording", "Screen Shot"]

    /// A screenshot or screen recording, by macOS's tag or, failing that, its name.
    static func isCapture(_ url: URL) -> Bool {
        if getxattr(url.path, tagName, nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        return namePrefixes.contains { name.hasPrefix($0) }
    }

    /// Tags a file Stackshot made the way macOS tags its own captures, so tidying and Spotlight treat it the same.
    static func markAsCapture(_ url: URL) {
        let result = tagValue.withUnsafeBytes { setxattr(url.path, tagName, $0.baseAddress, tagValue.count, 0, 0) }
        if result != 0 {
            Log.library.error("tag.failed file=\(url.lastPathComponent, privacy: .public) errno=\(errno)")
        }
    }

    private static let tagValue = (try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)) ?? Data()
}

/// Stackshot's own working folders under ~/Library/Caches.
enum AppPaths {
    static let bundleID = "com.leonmiltiadou.stackshot"

    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Flattened images and GIFs made for one shot. Created on demand.
    static func exports(for id: UUID) -> URL { folder(cache.appendingPathComponent("exports/\(id.uuidString)", isDirectory: true)) }

    /// Recordings while they're still being written. Created on demand.
    static var recordings: URL { folder(cache.appendingPathComponent("recordings", isDirectory: true)) }

    private static func folder(_ url: URL) -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.app.error("cache-folder.failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        return url
    }
}

extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }

    /// "3.4 MB", or nil if the file can't be read.
    var formattedFileSize: String? {
        guard let bytes = (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// "0:07", "12:34".
func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}
