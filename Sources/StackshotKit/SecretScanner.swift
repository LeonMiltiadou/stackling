import Foundation
import Vision

/// Spots things you wouldn't want in a shared screenshot: API keys, tokens, passwords, private keys,
/// emails, card numbers. Works on text only, so it can be tested without images.
enum SecretScanner {
    enum Kind: String, CaseIterable {
        case email, apiKey, token, jwt, password, privateKey, cardNumber
    }

    struct Match: Equatable {
        let kind: Kind
        let range: Range<String.Index>
    }

    /// Each pattern, what it is, and which capture group holds the secret itself
    /// (0 is the whole match; the password pattern only hides the value, not the word "password").
    private static let patterns: [(Kind, NSRegularExpression, group: Int)] = [
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, 0),
        // Anthropic, OpenAI and similar "sk-" keys; Stripe live keys.
        (.apiKey, #"\b(?:sk|rk|pk)[-_](?:ant-|live_|test_|proj-)?[A-Za-z0-9_-]{16,}"#, 0),
        (.apiKey, #"\bAKIA[0-9A-Z]{16}\b"#, 0),                      // AWS access key id
        (.apiKey, #"\bAIza[0-9A-Za-z_-]{35}\b"#, 0),                 // Google API key
        (.token, #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, 0),             // GitHub tokens
        (.token, #"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#, 0),
        (.token, #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, 0),             // Slack
        (.token, #"\bglpat-[A-Za-z0-9_-]{20,}"#, 0),                 // GitLab
        (.token, #"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{16,})"#, 1),
        (.jwt, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, 0),
        // Letters-only boundaries so DB_PASSWORD and OPENAI_API_KEY count too.
        (.password, #"(?i)(?<![A-Za-z])(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)(?![A-Za-z])["']?\s*[:=]\s*["']?([^\s"',;]{4,})"#, 1),
        // The password in a connection string: postgres://user:PASSWORD@host
        (.password, #"\b[a-z][a-z0-9+.-]*://[^\s:/@]+:([^\s@/]{3,})@"#, 1),
        (.privateKey, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, 0),
        (.cardNumber, #"\b(?:\d[ -]?){13,19}\b"#, 0),
    ].map { kind, pattern, group in
        // The patterns are fixed and tested, so a bad one is a programming error.
        (kind, try! NSRegularExpression(pattern: pattern), group)
    }

    /// Every secret-looking stretch of `text`, without overlaps.
    static func matches(in text: String) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Match] = []
        for (kind, regex, group) in patterns {
            for result in regex.matches(in: text, range: whole) {
                let nsRange = result.range(at: group)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { continue }
                if kind == .cardNumber, !passesLuhn(String(text[range])) { continue }
                if found.contains(where: { $0.range.overlaps(range) }) { continue }
                found.append(Match(kind: kind, range: range))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The checksum real card numbers pass, so order numbers and timestamps don't get blacked out.
    static func passesLuhn(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, pair in
            let (i, d) = pair
            guard i % 2 == 1 else { return total + d }
            let doubled = d * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }
}

/// Finds secrets in a screenshot: reads its text with Vision, then works out where each one sits.
enum SecretFinder {
    struct Found {
        let kind: SecretScanner.Kind
        /// In image pixels, origin top-left, matching `Annotation` coordinates.
        let rect: CGRect
    }

    /// A little breathing room around each box so no edge of a character peeks out.
    static let padding: CGFloat = 3

    static func find(in image: CGImage) async -> [Found] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Correction "fixes" tokens into dictionary words, which is exactly wrong here.
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                Log.editor.error("secrets.ocr-failed error=\(error.localizedDescription, privacy: .public)")
                return []
            }
            let size = CGSize(width: image.width, height: image.height)
            return (request.results ?? []).flatMap { observation in
                boxes(in: observation, imageSize: size)
            }
        }.value
    }

    private static func boxes(in observation: VNRecognizedTextObservation, imageSize: CGSize) -> [Found] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        return SecretScanner.matches(in: candidate.string).compactMap { match in
            // Vision often only knows where whole words are, so "KEY=sk-…" may come back as one box.
            // Covering a little too much is the safe side for secrets.
            guard let box = try? candidate.boundingBox(for: match.range)?.boundingBox else { return nil }
            // Vision uses 0...1 with the origin bottom-left; annotations use pixels from the top-left.
            let rect = CGRect(
                x: box.minX * imageSize.width,
                y: (1 - box.maxY) * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            ).insetBy(dx: -padding, dy: -padding)
            return Found(kind: match.kind, rect: rect)
        }
    }
}
