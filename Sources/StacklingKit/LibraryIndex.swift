import AppKit
import UniformTypeIdentifiers

/// Every picture and video Stackling knows about: the whole library (inbox, your folders, the archive)
/// plus captures in the save folder when that's somewhere else. Kept up to date as files come and go.
@MainActor
final class LibraryIndex: ObservableObject {
    static let shared = LibraryIndex()

    struct Item: Identifiable, Hashable {
        enum Kind: String { case still, video, gif }

        let url: URL
        let kind: Kind
        let created: Date
        /// Where it sits inside the library: nil for the top level, "Bugs", "Archive/2026-09"…
        let folder: String?
        /// When clean-up will clear it, for loose captures that aren't kept.
        var cleanup: Cleanup.Plan? = nil
        /// You pressed Keep on it.
        var kept = false
        /// The app and window it was taken in, when Stackling saw it happen ("Xcode · Checkout.swift").
        var source: String? = nil

        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        var isArchived: Bool { folder?.hasPrefix(Library.archiveName) == true }
    }

    /// Newest first.
    @Published private(set) var items: [Item] = []
    @Published private(set) var isScanning = false

    private var watchers: [FolderWatcher] = []
    private var pendingScan: DispatchWorkItem?
    /// FSEvents can fire many times while files are being written; wait for things to settle.
    private static let settleDelay: TimeInterval = 0.6

    /// Replaces what the library shows without scanning, for tests and the website's renders.
    func show(_ items: [Item]) {
        self.items = items.sorted { $0.created > $1.created }
    }

    func start() {
        guard watchers.isEmpty else { return }
        rescan()
        for folder in Self.roots() {
            watchers.append(FolderWatcher(url: folder) { [weak self] in self?.scheduleRescan() })
        }
        Log.library.info("index.start roots=\(Self.roots().count)")
    }

    func scheduleRescan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    func rescan() {
        let roots = Self.roots()
        let libraryRoot = Library.root, saveFolder = ScreenshotPrefs.screenshotFolder
        let usedDays = AppSettings.cleanupUsedDays, untouchedDays = AppSettings.cleanupUntouchedDays
        isScanning = true
        Task {
            let found = await Task.detached(priority: .utility) {
                Self.scan(roots: roots, libraryRoot: libraryRoot, saveFolder: saveFolder, usedDays: usedDays, untouchedDays: untouchedDays)
            }.value
            items = found
            isScanning = false
            Log.library.debug("index.scanned items=\(found.count)")
            SearchIndex.shared.update(for: found)
        }
    }

    /// Top-level folders you've made, for the sidebar (not the archive).
    var folders: [String] {
        Set(items.compactMap { $0.folder?.split(separator: "/").first.map(String.init) })
            .filter { $0 != Library.archiveName }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Scanning

    private static func roots() -> [URL] {
        let library = Library.root, save = ScreenshotPrefs.screenshotFolder
        let saveIsInside = save.standardizedFileURL.path.hasPrefix(library.standardizedFileURL.path)
        return saveIsInside ? [library] : [library, save]
    }

    nonisolated private static func scan(roots: [URL], libraryRoot: URL, saveFolder: URL, usedDays: Int, untouchedDays: Int) -> [Item] {
        var items: [Item] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        for root in roots {
            let isLibrary = root.standardizedFileURL == libraryRoot.standardizedFileURL
            // The library is walked all the way down; a save folder elsewhere (the Desktop, say) only for captures at its top.
            let options: FileManager.DirectoryEnumerationOptions = isLibrary
                ? [.skipsHiddenFiles, .skipsPackageDescendants]
                : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let kind = kind(of: url), seen.insert(url.standardizedFileURL.path).inserted else { continue }
                if !isLibrary && !CaptureFile.isCapture(url) { continue }
                let folder = isLibrary ? folderPath(of: url, in: libraryRoot) : nil
                let created = values.creationDate ?? .distantPast
                let note = Usage.read(url)
                // Mirrors Cleanup.cleanableFolder: only the library's own top level is ever cleared.
                let loose = isLibrary && folder == nil && CaptureFile.isCapture(url)
                    && saveFolder.standardizedFileURL == libraryRoot.standardizedFileURL
                let plan = loose ? Cleanup.plan(note: note, created: created, edited: Markup.hasEdits(url),
                                                usedDays: usedDays, untouchedDays: untouchedDays) : nil
                let source = [note.app, note.window].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                items.append(Item(url: url, kind: kind, created: created, folder: folder, cleanup: plan, kept: note.keep,
                                  source: source.isEmpty ? nil : source))
            }
        }
        return items.sorted { $0.created > $1.created }
    }

    nonisolated static func kind(of url: URL) -> Item.Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .gif) { return .gif }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) || type.conforms(to: .pdf) { return .still }
        return nil
    }

    nonisolated static func folderPath(of url: URL, in root: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard parent.hasPrefix(base + "/") else { return nil }
        return String(parent.dropFirst(base.count + 1))
    }
}
