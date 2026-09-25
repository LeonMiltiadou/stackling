import AppKit
import Foundation
import Testing
@testable import StacklingKit

struct LookAlikesTests {
    /// Draws a test picture: `stripes` dark bars on a light background, or a plain fill.
    private func picture(stripes: Int, size: CGSize = CGSize(width: 400, height: 300), dark: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lookalike-\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(dark ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        for i in 0..<stripes { context.fill(CGRect(x: 20, y: CGFloat(20 + i * 24), width: size.width - 40, height: 12)) }
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func findsThePictureThatLooksAlike() async throws {
        let new = try picture(stripes: 10)
        let twin = try picture(stripes: 10)
        let other = try picture(stripes: 0, dark: true)
        defer { [new, twin, other].forEach { try? FileManager.default.removeItem(at: $0) } }
        let matches = await LookAlikes(cacheURL: nil).closest(to: new, text: "", among: [
            .init(url: other, folder: "Dark", text: ""),
            .init(url: twin, folder: "Stripes", text: ""),
        ])
        #expect(matches.first?.folder == "Stripes")
        #expect((matches.first?.picture ?? 0) > (matches.last?.picture ?? 100))
    }

    @Test func unusualSharedWordsCountMost() {
        let docs = ["waymark audit worker the", "waymark audit settings the", "grafana latency the", "the the the"]
        let weights = LookAlikes.wordWeights(docs)
        let sameProject = LookAlikes.cosine(weights(docs[0]), weights(docs[1]))
        let unrelated = LookAlikes.cosine(weights(docs[0]), weights(docs[2]))
        #expect(sameProject > 0.3, "two of three meaningful words shared")
        #expect(unrelated < 0.05, "only 'the' in common, and that's everywhere")
    }

    @Test func wordsIgnoreShortBitsAndNumbers() {
        #expect(LookAlikes.words(in: "PR #9: cart.total is 42 ok") == ["cart", "total"])
    }

    @Test func pictureSimilarityScale() {
        #expect(LookAlikes.pictureSimilarity(distance: 0.35) == 1)
        #expect(LookAlikes.pictureSimilarity(distance: 1.2) == 0)
        #expect(LookAlikes.pictureSimilarity(distance: 2) == 0)
    }

    @Test func spotsSliversAndBlankGrabs() {
        #expect(ShotLook(width: 41, height: 295, busy: 0.19).isNearlyEmpty, "the 41-pixel sliver from the real test")
        #expect(ShotLook(width: 800, height: 600, busy: 0.01).isNearlyEmpty, "a flat, empty grab")
        #expect(!ShotLook(width: 800, height: 600, busy: 0.4).isNearlyEmpty)
    }

    @Test func measuresHowBusyAPictureIs() throws {
        let busy = try picture(stripes: 10), blank = try picture(stripes: 0)
        defer { [busy, blank].forEach { try? FileManager.default.removeItem(at: $0) } }
        let lookBusy = ShotLook.measure(NSImage(contentsOf: busy)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let lookBlank = ShotLook.measure(NSImage(contentsOf: blank)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        #expect(lookBusy.busy > 0.2)
        #expect(lookBlank.busy < 0.05)
        #expect(lookBlank.isNearlyEmpty)
    }
}

@MainActor
struct AutoFilerStateTests {
    @Test func tellsJevEverythingButThePicture() throws {
        let candidates: [LookAlikes.Candidate] = [
            .init(url: URL(fileURLWithPath: "/a.png"), folder: "Bugs", text: "TypeError cart.total undefined"),
            .init(url: URL(fileURLWithPath: "/b.png"), folder: "Bugs", text: ""),
        ]
        let state = AutoFiler.state(text: "checkout crashed", source: CaptureSource(app: "Arc", window: "PR 9"),
                                    look: ShotLook(width: 800, height: 600, busy: 0.4),
                                    lookAlikes: [.init(folder: "Bugs", picture: 80, words: 40)], candidates: candidates)
        #expect(state["screenshot_text"] as? String == "checkout crashed")
        #expect((state["captured_from"] as? [String: Any])?["app"] as? String == "Arc")
        #expect((state["folder_contents"] as? [String: [String]])?["Bugs"] == ["TypeError cart.total undefined"], "shots with no words are left out")
        #expect((state["look_alikes"] as? [[String: Any]])?.first?["folder"] as? String == "Bugs")
        #expect(state["picture_description"] == nil, "only added when a vision model has been asked")
        _ = try JSONSerialization.data(withJSONObject: state)
    }

    @Test func folderContentsKeepsAFewShortLinesPerFolder() {
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        let candidates = (0..<6).map { LookAlikes.Candidate(url: URL(fileURLWithPath: "/\($0).png"), folder: "Waymark", text: long) }
        let contents = AutoFiler.folderContents(candidates)
        #expect(contents["Waymark"]?.count == 4)
        #expect(contents["Waymark"]?.first?.split(separator: " ").count == 25)
    }

    @Test func picturesAreSentSmallAndPrivately() throws {
        let body = try JSONSerialization.jsonObject(with: PictureDescriber.body(jpeg: Data([1, 2, 3]))) as! [String: Any]
        let provider = body["provider"] as! [String: Any]
        #expect(provider["zdr"] as? Bool == true, "zero data retention")
        #expect(provider["data_collection"] as? String == "deny")
        #expect(body["model"] as? String == PictureDescriber.model)

        let big = CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let jpeg = try #require(PictureDescriber.smallJPEG(big))
        let small = try #require(NSBitmapImageRep(data: jpeg))
        #expect(small.pixelsWide == 512 && small.pixelsHigh == 256)
    }

    /// Costs about $0.000014. STACKLING_JEV_KEY=sk-or-… swift test --filter picturesGetDescribed
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STACKLING_JEV_KEY"]?.hasPrefix("sk-or-") == true))
    func picturesGetDescribed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("describe-\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        for (i, h) in [120, 200, 90, 260, 180, 310].enumerated() { context.fill(CGRect(x: 60 + i * 85, y: 40, width: 55, height: h)) }
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try await PictureDescriber.describe(url, key: ProcessInfo.processInfo.environment["STACKLING_JEV_KEY"]!)
        #expect(text.lowercased().contains("chart") || text.lowercased().contains("bar") || text.lowercased().contains("graph"))
    }
}
