import AppKit
import QuickLookThumbnailing

// Times Stackling's hot paths on a made-up 2,000-shot library. Nothing is shown on screen.
// Run with scripts/bench.sh. Compare against the numbers in AGENTS.md before and after a change.

func time(_ label: String, _ runs: Int = 1, _ body: () throws -> Void) rethrows {
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<runs { try body() }
    print(String(format: "%-42@ %8.1f ms", label as NSString, (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(runs)))
}

func timeAsync(_ label: String, _ runs: Int = 1, _ body: () async throws -> Void) async rethrows {
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<runs { try await body() }
    print(String(format: "%-42@ %8.1f ms", label as NSString, (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(runs)))
}

/// A screenshot-sized picture with a few lines of text on it, like a code editor.
func makeSampleShot(at url: URL) throws {
    let size = NSSize(width: 900, height: 560)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1120, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, line) in ["struct CheckoutSummary: View {", "    let cart: Cart", "    Text(\"Total: \\(cart.total)\")", "TypeError: cart.total is undefined"].enumerated() {
        (line as NSString).draw(at: NSPoint(x: 40, y: 480 - i * 40), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), .foregroundColor: NSColor.white])
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("stackling-bench", isDirectory: true)
let library = work.appendingPathComponent("library", isDirectory: true)
let sample = work.appendingPathComponent("sample.png")

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: sample.path) { try makeSampleShot(at: sample) }
        if !FileManager.default.fileExists(atPath: library.path) {
            let data = try Data(contentsOf: sample)
            for i in 0..<2000 {
                let folder = i % 5 == 0 ? "Archive/2026-0\(i % 9 + 1)" : (i % 3 == 0 ? "Bugs" : "")
                let dir = library.appendingPathComponent(folder)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent("Screenshot \(i).png"))
            }
        }

        print("== library, 2,000 shots")
        var items: [LibraryIndex.Item] = []
        time("scan", 3) {
            let walker = FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey], options: [.skipsHiddenFiles])!
            items = walker.compactMap { $0 as? URL }.compactMap { url in
                LibraryIndex.kind(of: url).map { LibraryIndex.Item(url: url, kind: $0, created: Date(), folder: LibraryIndex.folderPath(of: url, in: library)) }
            }
        }
        for (n, item) in items.enumerated() { SearchIndex.shared.remember("TypeError: cart.total is undefined, request \(n)", for: item.url) }
        time("search, first query (builds cache)") { _ = SearchIndex.shared.filter(items, query: "cart undefined") }
        time("search, one query", 20) { _ = SearchIndex.shared.filter(items, query: "cart undefined") }
        time("search, typing 8 letters", 5) { for k in 1...8 { _ = SearchIndex.shared.filter(items, query: String("checkout".prefix(k))) } }

        print("== one shot")
        await timeAsync("read text (Vision)", 5) { _ = await SearchIndex.readText(at: sample) }
        try? await timeAsync("thumbnail (Quick Look)", 10) {
            let request = QLThumbnailGenerator.Request(fileAt: sample, size: CGSize(width: 260, height: 170), scale: 2, representationTypes: .thumbnail)
            _ = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        }
        if CGPreflightScreenCaptureAccess() {
            try? await timeAsync("freeze screens, first") { _ = try await ScreenGrabber.freezeScreens(excluding: []) }
            try? await timeAsync("freeze screens, cached displays", 5) { _ = try await ScreenGrabber.freezeScreens(excluding: []) }
        } else {
            print("(freeze skipped: this terminal has no Screen Recording permission)")
        }
        exit(0)
    }
    NSApplication.shared.run()
}
