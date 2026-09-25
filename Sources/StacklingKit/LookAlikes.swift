import AppKit
import Vision

/// Which filed shots a new one resembles, by picture and by words, so your own filing teaches Jev what
/// each folder is for. Pictures are compared with Apple Vision feature prints (about 12 ms a shot, all on
/// this Mac); prints are cached so each file is only looked at once.
actor LookAlikes {
    static let shared = LookAlikes()

    struct Candidate: Sendable {
        let url: URL
        let folder: String
        let text: String
    }

    struct Match: Equatable, Sendable {
        let folder: String
        /// 0–100: how alike the pictures are.
        let picture: Int
        /// 0–100: how many of the same unusual words they share.
        let words: Int

        var json: [String: Any] { ["folder": folder, "picture_similarity": picture, "words_similarity": words] }
    }

    /// How many look-alikes Jev is shown.
    static let shown = 5

    private struct Entry: Codable {
        let modified: Double
        let print: Data
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var unsaved = 0
    /// Where prints are kept between launches; nil keeps them in memory only (tests).
    private let cacheURL: URL?

    init(cacheURL: URL? = AppPaths.cache.appendingPathComponent("look-alikes.plist")) {
        self.cacheURL = cacheURL
    }

    /// The candidates most like the shot at `url`, best first.
    func closest(to url: URL, text: String, among candidates: [Candidate]) async -> [Match] {
        loadIfNeeded()
        guard let mine = await print(for: url) else { return [] }
        let started = Date()
        let words = Self.wordWeights([text] + candidates.map(\.text))
        let myWords = words(text)
        var scored: [(score: Double, match: Match)] = []
        for candidate in candidates where candidate.url != url {
            guard let theirs = await print(for: candidate.url) else { continue }
            var distance: Float = 0
            guard (try? mine.computeDistance(&distance, to: theirs)) != nil else { continue }
            let picture = Self.pictureSimilarity(distance: distance)
            let shared = Self.cosine(myWords, words(candidate.text))
            scored.append((picture + shared, Match(folder: candidate.folder, picture: Int(picture * 100), words: Int(shared * 100))))
        }
        saveIfNeeded()
        Log.library.debug("lookalikes.compared candidates=\(candidates.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return scored.sorted { $0.score > $1.score }.prefix(Self.shown).map(\.match)
    }

    // MARK: Pictures

    /// Feature-print distances run from about 0.35 (near twins) to 1.2 (unrelated); this maps them to 0–1.
    nonisolated static func pictureSimilarity(distance: Float) -> Double {
        min(1, max(0, (1.2 - Double(distance)) / 0.85))
    }

    private func print(for url: URL) async -> VNFeaturePrintObservation? {
        let modified = url.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        if let entry = entries[url.path], entry.modified == modified,
           let print = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: entry.print) {
            return print
        }
        guard let image = await SearchIndex.firstImage(of: url) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try await VisionWork.perform([request], on: image)
        } catch {
            Log.library.error("lookalikes.print-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let print = request.results?.first else { return nil }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) {
            entries[url.path] = Entry(modified: modified, print: data)
            unsaved += 1
        }
        return print
    }

    // MARK: Words

    /// Unusual words count for more than common ones (tf-idf), so "Waymark" matters and "the" doesn't.
    nonisolated static func wordWeights(_ documents: [String]) -> (String) -> [String: Double] {
        let count = Double(max(documents.count, 1))
        var seenIn: [String: Double] = [:]
        for document in documents { for word in Set(words(in: document)) { seenIn[word, default: 0] += 1 } }
        return { text in
            var weights: [String: Double] = [:]
            for word in words(in: text) { weights[word, default: 0] += log(count / (seenIn[word] ?? 1)) }
            let norm = sqrt(weights.values.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? weights.mapValues { $0 / norm } : [:]
        }
    }

    nonisolated static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        a.reduce(0) { $0 + $1.value * (b[$1.key] ?? 0) }
    }

    nonisolated static func words(in text: String) -> [String] {
        let pieces = text.lowercased().split(whereSeparator: { (c: Character) in !c.isLetter && !c.isNumber })
        return pieces.filter { $0.count >= 3 && $0.first?.isLetter == true }.map(String.init)
    }

    // MARK: Cache

    private func loadIfNeeded() {
        guard !loaded, let cacheURL else { return }
        loaded = true
        do {
            entries = try PropertyListDecoder().decode([String: Entry].self, from: Data(contentsOf: cacheURL))
        } catch CocoaError.fileReadNoSuchFile {
            entries = [:]
        } catch {
            Log.library.error("lookalikes.cache-read-failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveIfNeeded() {
        guard unsaved > 0, let cacheURL else { return }
        unsaved = 0
        let live = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        entries = live
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(live).write(to: cacheURL, options: .atomic)
        } catch {
            Log.library.error("lookalikes.cache-write-failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// What a shot looks like at a glance: its size, and how much is going on in it.
struct ShotLook: Sendable {
    let width: Int
    let height: Int
    /// 0 = flat colour, 1 = detail everywhere.
    let busy: Double

    /// Accidental slivers and blank grabs: not worth asking anyone about.
    var isNearlyEmpty: Bool { min(width, height) < 64 || busy < 0.05 }

    var json: [String: Any] { ["pixels": "\(width)x\(height)"] }

    static func measure(_ url: URL) async -> ShotLook? {
        guard let image = await SearchIndex.firstImage(of: url) else { return nil }
        return measure(image)
    }

    /// Shrinks the picture to 64×64 greys and counts the 4×4 cells whose brightness varies.
    static func measure(_ image: CGImage) -> ShotLook {
        let side = 64, cell = 4
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0), let data = context.data else {
            return ShotLook(width: image.width, height: image.height, busy: 1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        var busyCells = 0
        for cy in stride(from: 0, to: side, by: cell) {
            for cx in stride(from: 0, to: side, by: cell) {
                var low = 255, high = 0
                for y in cy..<cy + cell { for x in cx..<cx + cell { let v = Int(pixels[y * side + x]); low = min(low, v); high = max(high, v) } }
                if high - low > 12 { busyCells += 1 }
            }
        }
        return ShotLook(width: image.width, height: image.height, busy: Double(busyCells) / Double((side / cell) * (side / cell)))
    }
}
