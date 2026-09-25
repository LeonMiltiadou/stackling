import Foundation

/// Asks your own Claude Code (the `claude` command, already signed in) to look at screenshots and
/// suggest names and folders. It runs headless, can only read files (no writing, no shell), and
/// ignores your personal Claude settings so nothing else in your setup gets involved.
enum ClaudeCode {
    /// One file's suggestion.
    struct Suggestion: Decodable, Equatable {
        /// The file name as it is now.
        let file: String
        /// A new name, without the extension.
        let name: String
        /// A folder in the library to file it into.
        let folder: String
        /// A few words on why, shown in the review window.
        let reason: String
    }

    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Code isn't installed. Get it from claude.com/claude-code, sign in once, then try again."
            case let .failed(detail): "Claude Code couldn't finish: \(detail)"
            case .timedOut: "Claude Code took too long, so Stackshot stopped it."
            }
        }
    }

    /// Most files to send in one go. Keeps a run to a minute or two and a few cents.
    static let maxFilesPerRun = 30
    static let timeout: Duration = .seconds(300)

    /// Where `claude` usually lives. Apps don't get your shell's PATH, so we look in the usual places,
    /// then ask a login shell as a last resort.
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        return loginShellLookup()
    }

    /// Suggests names and folders for `files`, all inside `folder`.
    static func suggest(for files: [URL], in folder: URL, existingFolders: [String], model: String) async throws -> [Suggestion] {
        guard let claude = executable() else { throw Failure.notInstalled }
        let batch = Array(files.prefix(maxFilesPerRun))
        Log.library.info("claude.start files=\(batch.count) model=\(model, privacy: .public)")
        let started = Date()

        let output = try await run(claude, arguments: [
            "-p", prompt(for: batch, existingFolders: existingFolders),
            "--model", model,
            "--tools", "Read,Glob",
            "--allowedTools", "Read,Glob",
            "--setting-sources", "",
            "--json-schema", schema,
            "--output-format", "json",
            "--no-session-persistence",
        ], in: folder)

        let suggestions = try decode(output)
        Log.library.info("claude.done suggestions=\(suggestions.count) seconds=\(Int(Date().timeIntervalSince(started)))")
        return suggestions
    }

    // MARK: Prompt

    static func prompt(for files: [URL], existingFolders: [String]) -> String {
        let folders = existingFolders.isEmpty ? "(none yet)" : existingFolders.map { "- \($0)" }.joined(separator: "\n")
        let list = files.map { "- \($0.lastPathComponent)" }.joined(separator: "\n")
        return """
        You're tidying a software developer's screenshots and screen recordings. They're all in the current folder.

        For each file below, open it with the Read tool to see what it shows. You can't open videos (.mov, .mp4): \
        judge those by their name and leave them in a sensible folder.

        For each file, suggest:
        - name: what it shows, 2 to 6 words, lowercase words joined by hyphens, no extension, no dates. \
        Be specific: "checkout-form-null-error" beats "error-screenshot".
        - folder: where it belongs. Strongly prefer one of the existing folders. Only make up a new folder \
        when none fits, and keep it to 1 to 3 words in Title Case.
        - reason: under 12 words on why.

        Existing folders:
        \(folders)

        Files:
        \(list)
        """
    }

    static let schema = """
    {"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{\
    "file":{"type":"string"},"name":{"type":"string"},"folder":{"type":"string"},"reason":{"type":"string"}},\
    "required":["file","name","folder","reason"]}}},"required":["files"]}
    """

    // MARK: Output

    private struct Envelope: Decodable {
        let is_error: Bool?
        let result: String?
        let structured_output: Plan?
    }

    private struct Plan: Decodable { let files: [Suggestion] }

    /// Reads Claude Code's `--output-format json` envelope.
    static func decode(_ data: Data) throws -> [Suggestion] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            Log.library.error("claude.unreadable output=\(text, privacy: .public)")
            throw Failure.failed("its answer wasn't readable")
        }
        if envelope.is_error == true {
            throw Failure.failed(envelope.result ?? "unknown error")
        }
        guard let plan = envelope.structured_output else { throw Failure.failed("it didn't return any suggestions") }
        return plan.files
    }

    // MARK: Running

    private static func run(_ executable: URL, arguments: [String], in folder: URL) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try process.run()
                    // Read before waiting, so a large answer can't fill the pipe and stall the process.
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        Log.library.error("claude.exit status=\(process.terminationStatus) stderr=\(detail, privacy: .public)")
                        throw Failure.failed(detail.isEmpty ? "exit code \(process.terminationStatus)" : detail)
                    }
                    return data
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timedOut
                }
                defer {
                    group.cancelAll()
                    if process.isRunning { process.terminate() }
                }
                return try await group.next()!
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func loginShellLookup() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "whence -p claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
