import AppKit
import CoreServices
import os

let log = Logger(subsystem: "com.leonmiltiadou.stackshot", category: "app")

/// Thin FSEvents wrapper for one folder.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

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
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return }
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

    init(store: ShotStore) {
        self.store = store
    }

    func start() {
        watch(ScreenshotPrefs.screenshotFolder)
        // The screenshot location can be changed from the ⌘⇧5 toolbar, so keep an eye on it.
        locationTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLocation() }
        }
    }

    func checkLocation() {
        let current = ScreenshotPrefs.screenshotFolder
        if current.standardizedFileURL != folder.standardizedFileURL { watch(current) }
    }

    private func watch(_ url: URL) {
        folder = url
        known.removeAll()
        for item in listing() { known[item.url] = item.modified }
        log.notice("Watching \(url.path, privacy: .public), \(self.known.count) existing files")
        watcher = FolderWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    private struct Item { let url: URL; let created: Date; let modified: Date }

    private func listing() -> [Item] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Item(url: url, created: v.creationDate ?? .distantPast, modified: v.contentModificationDate ?? .distantPast)
        }
    }

    func scan() {
        let startedWatching = launched.addingTimeInterval(-5)
        for item in listing() {
            if let previous = known[item.url] {
                if item.modified > previous {
                    known[item.url] = item.modified
                    store.fileChanged(item.url)
                }
                continue
            }
            let age = Date().timeIntervalSince(item.created)
            let fresh = item.created > startedWatching && age < 30
            guard fresh, mediaTypes.contains(item.url.pathExtension.lowercased()) else {
                known[item.url] = item.modified
                continue
            }
            if isScreenCapture(item.url) {
                known[item.url] = item.modified
                log.notice("New screenshot \(item.url.lastPathComponent, privacy: .public)")
                // Give the writer a beat to finish before we thumbnail it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.store.addCapture(item.url, created: item.created)
                }
            } else if age > 5 {
                // Not a screenshot, stop looking at it.
                known[item.url] = item.modified
            }
            // Otherwise leave it unknown: the screenshot metadata may land a moment later.
        }
        store.pruneMissing()
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot") || name.hasPrefix("Screen Recording") || name.hasPrefix("Screen Shot")
    }
}
