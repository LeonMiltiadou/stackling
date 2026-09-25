import AppKit
import UniformTypeIdentifiers

/// Describes a picture in a sentence or two, for the few shots with next to no words in them. Jev can't
/// see pictures, so this is its eyes. Opt-in (Settings › Library › Jev), only with an OpenRouter key, and
/// sent with zero data retention: providers that keep or train on data are skipped.
///
/// Tested on 31 hand-filed shots (September 2026): for shots with no words it lifted correct filing from
/// 4 to 15. Where there are words it made things worse, as small vision models invent product names,
/// so it's only used when the words and look-alikes aren't enough.
enum PictureDescriber {
    /// The cheapest vision model in the test and also the most accurate there: ~$0.000014 a picture, ~1.4 s.
    static let model = "inclusionai/ling-3.0-flash-vl"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// Longest side of the copy that's sent. Plenty to recognise a screen, and keeps the cost down.
    static let side: CGFloat = 512
    static let timeout: TimeInterval = 10

    static let prompt = """
        You are helping file this screenshot into a folder. In at most two short sentences say: what kind of \
        screen it is (terminal, code diff, web dashboard, app window, system dialog, chart, design, photo…), \
        which app, product or project it is from if visible, and what it is about. No preamble.
        """

    /// Only OpenRouter keys can reach a vision model; TypeSafe's own API is Jev alone.
    static var isAvailable: Bool { JevKey.provider() == .openrouter }

    /// `key` is for tests; the app uses the saved one.
    static func describe(_ url: URL, key: String? = nil, session: URLSession = .shared) async throws -> String {
        guard let key = key ?? JevKey.read(), Jev.Provider.forKey(key) == .openrouter else { throw Jev.Failure.noKey }
        guard let image = await SearchIndex.firstImage(of: url), let jpeg = smallJPEG(image) else { throw Jev.Failure.unreadable }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body(jpeg: jpeg)

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            Log.library.error("describe.rejected status=\(status) detail=\(detail, privacy: .public)")
            throw Jev.Failure.rejected(status: status, detail: detail)
        }
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard let text = try? JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw Jev.Failure.unreadable }
        Log.library.info("describe.done model=\(model, privacy: .public) kb=\(jpeg.count / 1024) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return String(text.prefix(600))
    }

    static func body(jpeg: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 400,
            "provider": ["zdr": true, "data_collection": "deny"],
            "reasoning": ["enabled": false],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
            ]]],
        ], options: [.sortedKeys])
    }

    /// A copy no bigger than `side` on its longest edge, as a 70% JPEG (typically 20–40 KB).
    static func smallJPEG(_ image: CGImage) -> Data? {
        let scale = min(1, side / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
