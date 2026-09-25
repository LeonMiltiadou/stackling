import Foundation

/// A private diary of what you do in Stackling, so the parts you use can be polished and the parts you
/// don't can be questioned. Off unless you turn it on (Settings › General). One JSON line per event, in a
/// file on this Mac that's never sent anywhere. It records what happened and how (a key, a button, a
/// menu, a drag), never file names, window titles or anything read from a shot.
///
/// Summarise it with `scripts/activity.sh [days]`.
enum ActivityLog {
    /// Every event Stackling can record. The catalogue is written at launch, so the summary can list
    /// the features that were never used.
    enum Event: String, CaseIterable {
        // App
        case launch = "app.launch", quit = "app.quit", settingChanged = "settings.change"
        // Capturing
        case captureStart = "capture.start", captureDone = "capture.done", captureCancel = "capture.cancel"
        case nativeCapture = "capture.native", recordStop = "record.stop", recordDiscard = "record.discard"
        case imported = "stack.import", shotNew = "shot.new"
        // A card on the stack
        case copy = "shot.copy", copyText = "shot.copy-text", copyGIF = "shot.copy-gif", copyPath = "shot.copy-path"
        case drag = "shot.drag", edit = "shot.edit", preview = "shot.preview", pin = "shot.pin", keep = "shot.keep"
        case dismiss = "shot.dismiss", trash = "shot.trash", file = "shot.file", share = "shot.share"
        case moveTo = "shot.move-to", saveGIF = "shot.save-gif", nameWithClaude = "shot.name-claude"
        case flatten = "shot.flatten", openInApp = "shot.open-in-app", reveal = "shot.reveal"
        // The stack itself
        case copyAll = "stack.copy-all", fileAll = "stack.file-all", keepAll = "stack.keep-all", clear = "stack.clear"
        case expand = "stack.expand", collapse = "stack.collapse", unshrink = "stack.unshrink", moveStack = "stack.move"
        case restore = "stack.restore"
        // Editor
        case hideSecrets = "editor.hide-secrets", editorUndo = "editor.undo", editorClose = "editor.close"
        // Preview of a recording
        case trim = "preview.trim", gifView = "preview.gif-view"
        // Pins
        case pinCopy = "pin.copy", pinClose = "pin.close", pinCloseAll = "pin.close-all"
        // Library
        case libraryOpen = "library.open", librarySearch = "library.search", librarySection = "library.section"
        case libraryOpenItem = "library.open-item", libraryQuickLook = "library.quick-look", libraryCopy = "library.copy"
        case libraryDrag = "library.drag", libraryTrash = "library.trash", libraryUndo = "library.put-back"
        case libraryKeep = "library.keep", libraryRename = "library.rename", libraryFile = "library.file"
        case libraryAddToStack = "library.add-to-stack", folderNew = "library.folder-new"
        case folderRename = "library.folder-rename", folderTrash = "library.folder-trash"
        // Helpers
        case tidyOpen = "tidy.open", tidyApply = "tidy.apply", autoFile = "autofile", cleanup = "cleanup"
    }

    /// Where it's kept. Plain text, one event per line, readable with any editor.
    static var fileURL: URL {
        if let testURL { return testURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppPaths.bundleID, isDirectory: true)
            .appendingPathComponent("activity.jsonl")
    }

    /// Tests point the log somewhere temporary and switch it on without touching settings.
    nonisolated(unsafe) static var testURL: URL?

    /// Past this size the log starts afresh (the old one is kept as activity.old.jsonl).
    static let maxBytes = 20 * 1024 * 1024

    private static let queue = DispatchQueue(label: "io.github.leonmiltiadou.stackling.activity", qos: .utility)

    /// How the action being recorded was started: "key", "menu", "drag"… Set around a call with `via`.
    nonisolated(unsafe) private static var trigger: String?

    /// Runs `body` with every event it records marked as coming from `how`.
    @discardableResult
    static func via<T>(_ how: String, _ body: () -> T) -> T {
        let outer = trigger
        trigger = how
        defer { trigger = outer }
        return body()
    }

    static func record(_ event: Event, _ details: [String: Any] = [:]) {
        guard testURL != nil || UserDefaults.standard.bool(forKey: DefaultsKey.activityLog) else { return }
        var line = details
        line["t"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        line["e"] = event.rawValue
        if line["via"] == nil, let trigger { line["via"] = trigger }
        guard JSONSerialization.isValidJSONObject(line),
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        queue.async { append(data + Data("\n".utf8)) }
    }

    /// The launch line carries the catalogue of events, so a summary can tell "never used" from "not logged".
    static func recordLaunch(version: String) {
        record(.launch, ["version": version, "catalogue": Event.allCases.map(\.rawValue)])
    }

    /// Waits for pending lines to be written, for quitting.
    static func flush() { queue.sync {} }

    private static func append(_ data: Data) {
        let url = fileURL
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                let old = url.deletingLastPathComponent().appendingPathComponent("activity.old.jsonl")
                try? manager.removeItem(at: old)
                try manager.moveItem(at: url, to: old)
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Log.app.error("activity.write-failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
