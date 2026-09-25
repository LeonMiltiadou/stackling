import AppKit

// The three places Stackling asks Jev something. Each is opt-in (Settings › Library › Jev), needs a key,
// and quietly does nothing, or the safe thing, when Jev isn't available.

// MARK: - Auto-file new captures

/// Files each new capture into the folder it belongs in, judged from the words in it.
@MainActor
enum AutoFiler {
    /// How sure Jev has to be before a shot is moved. Below this it stays where it is.
    static let minimumConfidence = 0.7
    static let noFolder = "none"

    static func consider(_ shot: Shot) {
        guard AppSettings.jevAutoFile else { return }
        guard Jev.isConfigured else { return Log.library.notice("autofile.skipped reason=no-key") }
        guard shot.isStill || shot.isVideo else { return Log.library.debug("autofile.skipped reason=gif") }
        let folders = Library.folders()
        guard !folders.isEmpty else { return Log.library.debug("autofile.skipped reason=no-folders") }
        Task {
            let text = await SearchIndex.readText(at: shot.url)
            guard !text.isEmpty else { return Log.library.info("autofile.skipped reason=no-text") }
            SearchIndex.shared.remember(text, for: shot.url)
            do {
                let answers = try await Jev.ask(state: ["screenshot_text": String(text.prefix(4000))],
                                                questions: ["folder": question(for: folders)])
                guard let folder = decide(answers["folder"], folders: folders) else {
                    Log.library.info("autofile.kept confidence=\(answers["folder"]?.confidence ?? 0)")
                    return
                }
                guard shot.exists, Library.file(shot, into: folder) else { return }
                shot.flashDone("Filed in \(folder.lastPathComponent)")
                Log.library.info("autofile.filed folder=\(folder.lastPathComponent, privacy: .public)")
            } catch {
                Log.library.error("autofile.failed error=\(error.localizedDescription, privacy: .public)")
            }
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
        return .choice("Which folder does this screenshot belong in, going by `screenshot_text`?", options: options)
    }

    /// The folder to move to, or nil to leave the shot alone (no answer, "none", or not sure enough).
    static func decide(_ answer: Jev.Answer?, folders: [URL]) -> URL? {
        guard let answer, let choice = answer.choice, choice != noFolder,
              (answer.confidence ?? 0) >= minimumConfidence else { return nil }
        return folders.first { $0.lastPathComponent == choice }
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
                                       "line": secret.line.replacingOccurrences(of: secret.text, with: "[candidate]")]
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
