import AppKit

// The three places Stackling asks Jev something. Each is opt-in (Settings › Library › Jev), needs a key,
// and quietly does nothing, or the safe thing, when Jev isn't available.

// MARK: - Auto-file new captures

/// Files each new capture into the folder it belongs in. Jev only reads text, so the shot is described in
/// words first, on this Mac: the words in it, the app and window it came from, which filed shots it looks
/// like, and what each folder already holds. Only when that's not enough (next to no words) can a vision
/// model describe the picture, if you've turned that on.
///
/// Tested against 31 hand-filed shots (September 2026), at a 60% bar:
///   words only: 14 filed right, 3 wrong · + look-alikes and folder contents: 21 right, 2 wrong.
@MainActor
enum AutoFiler {
    /// How sure Jev has to be before a shot is moved. Below this it stays where it is.
    static let minimumConfidence = 0.6
    static let noFolder = "none"
    /// Fewer words than this and the words alone say little; that's when the picture gets described.
    static let fewWords = 10
    /// Filed shots compared per folder (the newest), which keeps a big library quick.
    static let comparedPerFolder = 200

    static let instructions = "Which folder does this screenshot belong in? Use `screenshot_text` (words read from it), "
        + "`captured_from` (the app and window it was taken in), `folder_contents` (words read from shots already in each "
        + "folder) and `look_alikes` (filed shots that resemble it most, by picture and by words)."

    static func consider(_ shot: Shot, source: CaptureSource?) {
        guard AppSettings.jevAutoFile else { return }
        guard Jev.isConfigured else { return Log.library.notice("autofile.skipped reason=no-key") }
        guard shot.isStill || shot.isVideo else { return Log.library.debug("autofile.skipped reason=gif") }
        let folders = Library.folders()
        guard !folders.isEmpty else { return Log.library.debug("autofile.skipped reason=no-folders") }
        Task { await file(shot, folders: folders, source: source) }
    }

    private static func file(_ shot: Shot, folders: [URL], source: CaptureSource?) async {
        let started = Date()
        let text = await SearchIndex.readText(at: shot.url)
        if !text.isEmpty { SearchIndex.shared.remember(text, for: shot.url) }
        let look = await ShotLook.measure(shot.url)
        if text.isEmpty, look?.isNearlyEmpty ?? true { return Log.library.info("autofile.skipped reason=nearly-empty") }

        let candidates = candidates(in: folders)
        let lookAlikes = await LookAlikes.shared.closest(to: shot.url, text: text, among: candidates)
        var state = state(text: text, source: source, look: look, lookAlikes: lookAlikes, candidates: candidates)
        let question = ["folder": question(for: folders)]
        do {
            var answer = try await Jev.ask(state: state, questions: question)["folder"]
            var described = false
            if decide(answer, folders: folders) == nil, text.split(separator: " ").count < fewWords,
               AppSettings.jevDescribePictures, PictureDescriber.isAvailable {
                state["picture_description"] = try await PictureDescriber.describe(shot.url)
                answer = try await Jev.ask(state: state, questions: question)["folder"]
                described = true
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let folder = decide(answer, folders: folders) else {
                Log.library.info("autofile.kept guess=\(answer?.choice ?? "-", privacy: .public) confidence=\(answer?.confidence ?? 0) described=\(described) ms=\(ms)")
                return
            }
            guard shot.exists, Library.file(shot, into: folder) else { return }
            shot.flashDone("Filed in \(folder.lastPathComponent)")
            Log.library.info("autofile.filed folder=\(folder.lastPathComponent, privacy: .public) confidence=\(answer?.confidence ?? 0) described=\(described) lookalikes=\(lookAlikes.count) ms=\(ms)")
        } catch {
            Log.library.error("autofile.failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything Jev is told about the shot. All of it is text; the picture itself only goes anywhere
    /// through `PictureDescriber`, and only if you've turned that on.
    static func state(text: String, source: CaptureSource?, look: ShotLook?, lookAlikes: [LookAlikes.Match],
                      candidates: [LookAlikes.Candidate]) -> [String: Any] {
        var state: [String: Any] = [
            "screenshot_text": String(text.prefix(4000)),
            "folder_contents": folderContents(candidates),
            "look_alikes": lookAlikes.map(\.json),
        ]
        if let source { state["captured_from"] = source.json }
        if let look { state["picture"] = look.json }
        return state
    }

    /// A few lines from the newest shots in each folder, so Jev knows what the folder is for.
    static func folderContents(_ candidates: [LookAlikes.Candidate], perFolder: Int = 4, words: Int = 25) -> [String: [String]] {
        var contents: [String: [String]] = [:]
        for candidate in candidates where !candidate.text.isEmpty && contents[candidate.folder, default: []].count < perFolder {
            contents[candidate.folder, default: []].append(candidate.text.split(separator: " ").prefix(words).joined(separator: " "))
        }
        return contents
    }

    /// The filed shots worth comparing against: the newest in each folder, with any words already read.
    private static func candidates(in folders: [URL]) -> [LookAlikes.Candidate] {
        folders.flatMap { folder in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                      options: .skipsHiddenFiles)) ?? []
            return files.filter { LibraryIndex.kind(of: $0) != nil }
                .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
                .prefix(comparedPerFolder)
                .map { LookAlikes.Candidate(url: $0, folder: folder.lastPathComponent, text: SearchIndex.shared.text(for: $0) ?? "") }
        }
    }

    /// The question: one option per folder (with a few of its file names as examples), plus "none".
    static func question(for folders: [URL]) -> Jev.Question {
        var options: [String: String] = [noFolder: "None of these folders clearly fits; leave it where it is."]
        for folder in folders.prefix(254) {
            let examples = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                .filter { !$0.hasPrefix(".") }.prefix(3).joined(separator: ", ") ?? ""
            options[folder.lastPathComponent] = "The folder \"\(folder.lastPathComponent)\"" + (examples.isEmpty ? "" : ". It already holds: \(examples)")
        }
        return .choice(instructions, options: options)
    }

    /// The folder to move to, or nil to leave the shot alone (no answer, "none", or not sure enough).
    static func decide(_ answer: Jev.Answer?, folders: [URL]) -> URL? {
        guard let answer, let choice = answer.choice, choice != noFolder,
              (answer.confidence ?? 0) >= minimumConfidence else { return nil }
        return folders.first { $0.lastPathComponent == choice }
    }
}

/// The app and window you were in when a shot was taken: the front-most ordinary window that isn't
/// Stackling's. Window titles need the Screen Recording permission, which Stackling already has.
struct CaptureSource: Equatable, Sendable {
    let app: String
    let window: String

    var json: [String: Any] { ["app": app, "window": window] }

    static func frontmost() -> CaptureSource? {
        let me = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = info.first(where: {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) != me
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }) else { return nil }
        return CaptureSource(app: window[kCGWindowOwnerName as String] as? String ?? "",
                             window: String((window[kCGWindowName as String] as? String ?? "").prefix(200)))
    }
}

// MARK: - A second opinion on Hide Secrets

/// Asks Jev whether each thing Hide Secrets found looks like a real secret, so examples and placeholders
/// stay readable. The secret itself never leaves this Mac: Jev sees a masked description and the line
/// around it with the value swapped out.
enum SecretCheck {
    /// Below this chance of being real, a match is left uncovered. Kept low: hiding too much is the safe side.
    static let keepAbove = 0.3

    static func filter(_ found: [SecretFinder.Found]) async -> [SecretFinder.Found] {
        guard AppSettings.jevCheckSecrets, Jev.isConfigured, !found.isEmpty else { return found }
        var state: [String: Any] = [:]
        var questions: [String: Jev.Question] = [:]
        for (i, secret) in found.enumerated() {
            state["candidate_\(i)"] = ["kind": secret.kind.rawValue, "looks_like": mask(secret.text),
                                       "line": line(around: secret, among: found)]
            questions["real_\(i)"] = .yesNo(
                "Is `candidate_\(i)` a real, working secret (a live key, token, password, email or card number) rather than an example, placeholder or ordinary text?"
            )
        }
        do {
            let answers = try await Jev.ask(state: state, questions: questions)
            let kept = found.enumerated().filter { i, _ in (answers["real_\(i)"]?.noul ?? 1) > keepAbove }.map(\.element)
            Log.editor.info("secrets.checked found=\(found.count) kept=\(kept.count)")
            return kept
        } catch {
            // No answer means no second opinion: cover everything, as without Jev.
            return found
        }
    }

    /// The line a match sits on, with it and every other match swapped out, so a second secret on the same
    /// line (`KEY=… SECRET=…`) never travels in plain text either.
    static func line(around secret: SecretFinder.Found, among found: [SecretFinder.Found]) -> String {
        var line = secret.line
        for other in found where !other.text.isEmpty && other.text != secret.text {
            line = line.replacingOccurrences(of: other.text, with: "[another candidate]")
        }
        return secret.text.isEmpty ? line : line.replacingOccurrences(of: secret.text, with: "[candidate]")
    }

    /// What Jev is allowed to see instead of the secret: its first few characters, length and make-up.
    /// "sk_live_51HxQ…" becomes "sk_l… (32 characters: letters, digits, symbols)".
    static func mask(_ secret: String) -> String {
        var kinds: [String] = []
        if secret.contains(where: \.isLetter) { kinds.append("letters") }
        if secret.contains(where: \.isNumber) { kinds.append("digits") }
        if secret.contains(where: { !$0.isLetter && !$0.isNumber }) { kinds.append("symbols") }
        let shown = secret.count > 12 ? String(secret.prefix(4)) + "…" : "…"
        return "\(shown) (\(secret.count) characters: \(kinds.joined(separator: ", ")))"
    }
}

// MARK: - Spotting junk when tidying

/// Asks Jev which shots in a tidy-up look accidental, blank or not worth keeping, so the review list can
/// suggest binning them. Nothing is binned unless you tick it.
enum JunkSpotter {
    /// From this chance up, the review list suggests the Trash.
    static let suggestAbove = 0.6

    /// Chance each file is junk, by file. Empty when Jev is off or unavailable.
    static func junkChances(for files: [URL]) async -> [URL: Double] {
        guard AppSettings.jevSpotJunk, Jev.isConfigured, !files.isEmpty else { return [:] }
        var state: [String: Any] = [:]
        var questions: [String: Jev.Question] = [:]
        for (i, file) in files.enumerated() {
            let text = await SearchIndex.readText(at: file)
            state["shot_\(i)"] = ["name": file.lastPathComponent, "text": String(text.prefix(1500)),
                                  "has_text": !text.isEmpty]
            questions["junk_\(i)"] = .yesNo(
                "Is `shot_\(i)` an accidental, blank, duplicate-looking or otherwise throwaway screenshot that isn't worth keeping?"
            )
        }
        do {
            let answers = try await Jev.ask(state: state, questions: questions)
            var chances: [URL: Double] = [:]
            for (i, file) in files.enumerated() { chances[file] = answers["junk_\(i)"]?.noul }
            return chances
        } catch {
            return [:]
        }
    }
}
