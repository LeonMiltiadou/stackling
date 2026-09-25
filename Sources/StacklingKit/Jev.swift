import Foundation
import Security
import os

/// TypeSafe's Jev ("System One"): answers typed questions about some text (a yes/no probability or a
/// choice from options you give it) in about a tenth of a second, for fractions of a penny.
/// Stackling uses it for small, frequent decisions. It's opt-in, needs your own key, and is only ever
/// sent text Stackling has read from a shot, never the picture itself.
enum Jev {
    /// Where to send questions. TypeSafe's own API, or OpenRouter's copy of it (same request and answers),
    /// chosen by the key: OpenRouter keys start with "sk-or-".
    enum Provider: String {
        case typesafe, openrouter

        static func forKey(_ key: String) -> Provider { key.hasPrefix("sk-or-") ? .openrouter : .typesafe }

        var endpoint: URL {
            switch self {
            case .typesafe: URL(string: "https://api.typesafe.ai/v1/systemone")!
            case .openrouter: URL(string: "https://openrouter.ai/api/v1/systemone")!
            }
        }

        var name: String { self == .openrouter ? "OpenRouter" : "TypeSafe" }
    }

    static let model = "jev-latest"
    /// Jev usually answers in 70–500 ms; anything slower isn't worth waiting for in a capture.
    static let timeout: TimeInterval = 8

    enum Question {
        /// "Is this…?" Jev answers with the probability of yes.
        case yesNo(String)
        /// Pick one of `options` (key → when it applies). Jev answers with a key and its confidence.
        case choice(String, options: [String: String])

        var json: [String: Any] {
            switch self {
            case let .yesNo(instructions):
                ["type": "noul", "instructions": instructions]
            case let .choice(instructions, options):
                ["type": "choice", "instructions": instructions, "criteria": options]
            }
        }
    }

    struct Answer: Decodable, Equatable {
        let type: String
        /// Yes/no questions: the probability of yes.
        let noul: Double?
        /// Choice questions: the option picked, how likely each option was, and how sure Jev is overall.
        let choice: String?
        let probabilities: [String: Double]?
        let confidence: Double?
    }

    enum Failure: LocalizedError {
        case noKey
        case rejected(status: Int, detail: String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noKey: "Add a TypeSafe or OpenRouter key in Settings › Library to use Jev."
            case let .rejected(status, detail): "Jev said no (\(status)): \(detail)"
            case .unreadable: "Jev's answer wasn't readable."
            }
        }
    }

    /// Only checks a key is saved; doesn't read it, so it never brings up a Keychain prompt.
    static var isConfigured: Bool { JevKey.exists() }

    /// Asks every question about `state` in one request.
    static func ask(state: Any, questions: [String: Question], session: URLSession = .shared) async throws -> [String: Answer] {
        guard let key = JevKey.read() else { throw Failure.noKey }
        return try await ask(state: state, questions: questions, key: key, session: session)
    }

    /// The same, with the key given directly (tests, and anything that isn't the saved key).
    static func ask(state: Any, questions: [String: Question], key: String, session: URLSession = .shared) async throws -> [String: Answer] {
        let provider = Provider.forKey(key)
        var request = URLRequest(url: provider.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body(state: state, questions: questions)

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            Log.library.error("jev.rejected status=\(status) detail=\(detail, privacy: .public)")
            throw Failure.rejected(status: status, detail: detail)
        }
        let answers = try decode(data)
        Log.library.info("jev.answered provider=\(provider.rawValue, privacy: .public) questions=\(questions.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return answers
    }

    static func body(state: Any, questions: [String: Question]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "state": state,
            "questions": questions.mapValues(\.json),
        ], options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> [String: Answer] {
        struct Envelope: Decodable { let answers: [String: Answer] }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).answers
        } catch {
            Log.library.error("jev.unreadable error=\(error.localizedDescription, privacy: .public)")
            throw Failure.unreadable
        }
    }
}

/// The TypeSafe or OpenRouter key, kept in the macOS Keychain rather than in settings files.
/// Read once per launch and kept in memory: reading it can bring up "Stackling wants to access key…",
/// and that should happen at most once, not on every capture.
enum JevKey {
    private static let service = "io.github.leonmiltiadou.stackling.typesafe"
    private static let account = "api-key"

    private enum Cached { case unknown, key(String), none }
    private static let cache = OSAllocatedUnfairLock(initialState: Cached.unknown)

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Whether a key is saved. Asks only for the item's attributes, which never needs your permission.
    static func exists() -> Bool {
        switch cache.withLock({ $0 }) {
        case .key: return true
        case .none: return false
        case .unknown: break
        }
        var q = query
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Which service the saved key is for, without reading the key: it's noted alongside it when saved.
    static func provider() -> Jev.Provider? {
        if case let .key(key) = cache.withLock({ $0 }) { return Jev.Provider.forKey(key) }
        var q = query
        q[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let comment = (item as? [String: Any])?[kSecAttrComment as String] as? String else { return nil }
        return Jev.Provider(rawValue: comment)
    }

    static func read() -> String? {
        switch cache.withLock({ $0 }) {
        case let .key(key): return key
        case .none: return nil
        case .unknown: break
        }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { Log.app.error("jev.key-read-failed status=\(status)") }
            // Denied at the prompt: stop asking until the next launch, or until a key is saved in Settings.
            if status == errSecUserCanceled || status == errSecAuthFailed { cache.withLock { $0 = .none } }
            return nil
        }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        cache.withLock { $0 = .key(key) }
        return key
    }

    /// Saved by Stackling itself, so the Keychain treats it as Stackling's and doesn't ask to read it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        remove()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrComment as String] = Jev.Provider.forKey(key).rawValue
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { Log.app.error("jev.key-save-failed status=\(status)") }
        if status == errSecSuccess { cache.withLock { $0 = .key(key) } }
        return status == errSecSuccess
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
        cache.withLock { $0 = .unknown }
    }
}
