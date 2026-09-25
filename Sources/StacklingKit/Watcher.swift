import AppKit
import CoreServices

/// Thin FSEvents wrapper for one folder.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// How long FSEvents may gather changes before telling us.
    private static let latency: CFTimeInterval = 0.1

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags
        ) else {
            Log.library.error("watch.stream-failed path=\(url.path, privacy: .public)")
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Watches the folder macOS saves screenshots into and feeds new ones to the stack.
/// This is what lets the native ⌘⇧3 / ⌘⇧4 / ⌘⇧5 keep working exactly as before.
@MainActor
final class ScreenshotWatcher {
    private let store: ShotStore
    private(set) var folder: URL = ScreenshotPrefs.screenshotFolder
    private var watcher: FolderWatcher?
    private var known: [URL: Date] = [:]
    private let launched = Date()
    private var locationTimer: Timer?

    private let mediaTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf", "bmp", "mov", "mp4"]

    /// How often to check whether the save folder moved (the ⌘⇧5 toolbar can change it behind our back).
    private static let locationCheckInterval: TimeInterval = 3
    /// Files made up to this long before launch still count as new, so a capture taken while we started isn't missed.
    private static let launchGrace: TimeInterval = 5
    /// Only files younger than this are treated as fresh captures.
    private static let freshAge: TimeInterval = 30
    /// How long to wait for macOS's screenshot tag before deciding a file isn't a capture.
    private static let tagGrace: TimeInterval = 5
    /// Gives the writer a beat to finish before we thumbnail the file.
    /// How long to wait before checking again on a file that's still being written, and how many times.
    private static let readyRetry: TimeInterval = 0.04
    private static let readyAttempts = 8

    init(store: ShotStore) {
        self.store = store
    }

    func start() {
        watch(ScreenshotPrefs.screenshotFolder)
        locationTimer = Timer.scheduledTimer(withTimeInterval: Self.locationCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLocation() }
        }
    }

    func checkLocation() {
        let current = ScreenshotPrefs.screenshotFolder
        guard current.standardizedFileURL != folder.standardizedFileURL else { return }
        Log.library.notice("save-folder.changed from=\(self.folder.path, privacy: .public) to=\(current.path, privacy: .public)")
        watch(current)
    }

    private func watch(_ url: URL) {
        folder = url
        known.removeAll()
        for item in listing() { known[item.url] = item.modified }
        Log.library.notice("watch.start path=\(url.path, privacy: .public) existing=\(self.known.count)")
        watcher = FolderWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    private struct Item { let url: URL; let created: Date; let modified: Date }

    private func listing() -> [Item] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            Log.library.error("watch.list-failed path=\(self.folder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Item(url: url, created: v.creationDate ?? .distantPast, modified: v.contentModificationDate ?? .distantPast)
        }
    }

    func scan() {
        let startedWatching = launched.addingTimeInterval(-Self.launchGrace)
        for item in listing() {
            if let previous = known[item.url] {
                if item.modified > previous {
                    known[item.url] = item.modified
                    store.fileChanged(item.url)
                }
                continue
            }
            let age = Date().timeIntervalSince(item.created)
            let fresh = item.created > startedWatching && age < Self.freshAge
            guard fresh, mediaTypes.contains(item.url.pathExtension.lowercased()) else {
                known[item.url] = item.modified
                Log.library.debug("watch.skipped file=\(item.url.lastPathComponent, privacy: .public) reason=\(fresh ? "not-media" : "not-fresh", privacy: .public)")
                continue
            }
            if CaptureFile.isCapture(item.url) {
                known[item.url] = item.modified
                Log.library.notice("capture.new file=\(item.url.lastPathComponent, privacy: .public)")
                addWhenReady(item.url, created: item.created)
            } else if age > Self.tagGrace {
                // Not a screenshot, stop looking at it.
                known[item.url] = item.modified
                Log.library.debug("watch.skipped file=\(item.url.lastPathComponent, privacy: .public) reason=not-capture")
            }
            // Otherwise leave it unknown: the screenshot metadata may land a moment later.
        }
        store.pruneMissing()
    }

    /// Adds a capture as soon as it reads back complete. macOS writes screenshots in one go, so that's
    /// usually straight away; a file still being written gets a few short retries.
    private func addWhenReady(_ url: URL, created: Date, attempt: Int = 0) {
        guard !CaptureFile.isComplete(url), attempt < Self.readyAttempts else {
            if attempt > 0 { Log.library.debug("capture.ready file=\(url.lastPathComponent, privacy: .public) retries=\(attempt)") }
            // Taken with the Mac's own shortcuts (⇧⌘3, ⇧⌘5…): Stackling's own captures arrive another way.
            if !CaptureFile.wasMadeHere(url) {
                ActivityLog.record(.nativeCapture, ["kind": LibraryIndex.kind(of: url)?.rawValue ?? "other"])
            }
            store.addCapture(url, created: created)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyRetry) { [weak self] in
            self?.addWhenReady(url, created: created, attempt: attempt + 1)
        }
    }
}
