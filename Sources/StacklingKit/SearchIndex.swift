import AVFoundation
import AppKit
import Vision

/// The words inside every shot, so the library can find "that error about cart.total" from last week.
/// Text is read on this Mac with Vision, once per file (again only if the file changes), in the
/// background at low priority, and cached between launches.
@MainActor
final class SearchIndex: ObservableObject {
    static let shared = SearchIndex()

    private struct Entry: Codable {
        let modified: Double
        let text: String
    }

    /// Files still waiting to be read; the library shows this while it's catching up.
    @Published private(set) var pending = 0

    private var entries: [String: Entry] = [:]
    private var queue: [URL] = []
    private var worker: Task<Void, Never>?
    private var loaded = false
    private var unsaved = 0
    /// Save the cache every so often while reading, so a quit doesn't lose much work.
    private static let saveEvery = 20

    private static var cacheURL: URL { AppPaths.cache.appendingPathComponent("search-index.json") }

    // MARK: Asking

    /// True when every word of `query` appears in the shot's name, its folder or its text.
    func matches(_ item: LibraryIndex.Item, query: String) -> Bool {
        matches(item, words: Self.words(in: query))
    }

    /// The shots in `items` that match `query`, in the same order.
    func filter(_ items: [LibraryIndex.Item], query: String) -> [LibraryIndex.Item] {
        let words = Self.words(in: query)
        return words.isEmpty ? items : items.filter { matches($0, words: words) }
    }

    private func matches(_ item: LibraryIndex.Item, words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = haystack(for: item)
        return words.allSatisfy { haystack.range(of: $0, options: .literal).location != NSNotFound }
    }

    /// Name, folder and text, lower-cased once and kept, so each keystroke is just a string search.
    private var haystacks: [String: NSString] = [:]

    private func haystack(for item: LibraryIndex.Item) -> NSString {
        if let cached = haystacks[item.url.path] { return cached }
        let built = [item.name, item.folder ?? "", entries[item.url.path]?.text ?? ""].joined(separator: " ").lowercased() as NSString
        haystacks[item.url.path] = built
        return built
    }

    nonisolated static func words(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Sets a shot's text directly, for tests and the website's renders.
    func remember(_ text: String, for url: URL) {
        entries[url.path] = Entry(modified: url.modificationDate?.timeIntervalSinceReferenceDate ?? 0, text: text)
        haystacks[url.path] = nil
    }

    // MARK: Keeping up

    /// Queues anything new or changed since it was last read, newest first.
    func update(for items: [LibraryIndex.Item]) {
        loadIfNeeded()
        let live = Set(items.map(\.url.path))
        entries = entries.filter { live.contains($0.key) }
        haystacks = haystacks.filter { live.contains($0.key) }
        queue = items.compactMap { item in
            let modified = item.url.modificationDate?.timeIntervalSinceReferenceDate ?? 0
            return entries[item.url.path]?.modified == modified ? nil : item.url
        }
        pending = queue.count
        guard !queue.isEmpty, worker == nil else { return }
        Log.library.info("search.index queued=\(self.queue.count)")
        worker = Task { await work() }
    }

    /// How many shots are read at the same time. Vision work runs at background priority, on the
    /// efficiency cores, so a few in parallel finish sooner without getting in anyone's way.
    private static let parallelReads = 3

    private func work() async {
        let started = Date()
        var done = 0
        while !queue.isEmpty {
            let batch = Array(queue.prefix(Self.parallelReads))
            queue.removeFirst(batch.count)
            let read = await withTaskGroup(of: (URL, Double, String).self) { group in
                for url in batch {
                    group.addTask(priority: .background) {
                        (url, url.modificationDate?.timeIntervalSinceReferenceDate ?? 0, await Self.readText(at: url))
                    }
                }
                var results: [(URL, Double, String)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (url, modified, text) in read {
                entries[url.path] = Entry(modified: modified, text: text)
                haystacks[url.path] = nil
            }
            done += read.count
            pending = queue.count
            unsaved += read.count
            if unsaved >= Self.saveEvery { save() }
        }
        Log.library.info("search.index read=\(done) seconds=\(Int(Date().timeIntervalSince(started)))")
        save()
        worker = nil
        Log.library.info("search.index done entries=\(self.entries.count)")
    }

    // MARK: Reading text

    nonisolated static func readText(at url: URL) async -> String {
        guard let image = await firstImage(of: url) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// The picture itself, the first frame of a GIF, or a frame from the middle of a video.
    nonisolated private static func firstImage(of url: URL) async -> CGImage? {
        if LibraryIndex.kind(of: url) == .video {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            return try? await generator.image(at: CMTime(seconds: max(seconds / 2, 0), preferredTimescale: 600)).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Cache

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: Self.cacheURL))
            Log.library.debug("search.cache-loaded entries=\(self.entries.count)")
        } catch CocoaError.fileReadNoSuchFile {
            entries = [:]
        } catch {
            Log.library.error("search.cache-read-failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        unsaved = 0
        do {
            try FileManager.default.createDirectory(at: AppPaths.cache, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: Self.cacheURL, options: .atomic)
        } catch {
            Log.library.error("search.cache-write-failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
