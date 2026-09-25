import AppKit

/// Where screenshots live, and how they stay tidy.
///
///     ~/Pictures/Stackshot/
///         new captures land here (the inbox), tidied up after a few days
///         Archive/2026-09/   where tidied shots go (unless you pick Trash)
///         <your folders>/    anything you file somewhere is yours and never touched
@MainActor
enum Library {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Stackshot", isDirectory: true)
    }

    static var archive: URL { root.appendingPathComponent("Archive", isDirectory: true) }

    /// First launch of a version with a library: screenshots stop landing on the Desktop.
    /// Only moves the save location if it was still the macOS default.
    static func adoptIfOnDesktop() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "library.adopted") else { return }
        d.set(true, forKey: "library.adopted")
        guard Prefs.screenshotFolder.standardizedFileURL == Prefs.desktop.standardizedFileURL else { return }
        Prefs.setScreenshotFolder(root)
        log.notice("Screenshots now save to \(root.path, privacy: .public)")
    }

    // MARK: Folders

    /// Folders you've filed shots into, most recently used first.
    static func folders() -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && $0.lastPathComponent != "Archive" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
    }

    /// Moves a shot (and its edits) into a folder in the library.
    @discardableResult
    static func file(_ shot: Shot, into folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = try move(shot.url, into: folder)
            shot.url = dest
            // Bumps the folder to the top of the list next time.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func askForNewFolder() -> URL? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "New folder"
        alert.informativeText = "Inside your Stackshot library. Anything you file here is kept, never tidied away."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Checkout bug"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create and File")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Moves a file and its sidecar into `folder`, picking a free name. Returns where it ended up.
    static func move(_ url: URL, into folder: URL) throws -> URL {
        let dest = freeName(url.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: url, to: dest)
        let sidecar = Markup.sidecarURL(for: url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.moveItem(at: sidecar, to: Markup.sidecarURL(for: dest))
        }
        return dest
    }

    static func freeName(_ name: String, in folder: URL) -> URL {
        var dest = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        return dest
    }

    // MARK: Tidy-up

    enum TidyAction: String { case archive, trash }

    /// Screenshots and recordings sitting loose in the inbox (not in any folder you made).
    static func looseCaptures(in folder: URL) -> [(url: URL, created: Date)] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, isCapture(url) else { return nil }
            return (url, v.creationDate ?? .distantPast)
        }
    }

    static func isCapture(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot") || name.hasPrefix("Screen Recording") || name.hasPrefix("Screen Shot")
    }

    /// Archives (or trashes) inbox captures older than the tidy setting. Leaves anything still on the stack alone.
    static func tidy(store: ShotStore) {
        let days = Settings.tidyAfterDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let onStack = Set(store.shots.map(\.url.standardizedFileURL))
        let old = looseCaptures(in: Prefs.screenshotFolder).filter { $0.created < cutoff && !onStack.contains($0.url.standardizedFileURL) }
        guard !old.isEmpty else { return }

        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        var done = 0
        for item in old {
            do {
                switch Settings.tidyAction {
                case .trash:
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    try? FileManager.default.removeItem(at: Markup.sidecarURL(for: item.url))
                case .archive:
                    let folder = archive.appendingPathComponent(month.string(from: item.created), isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    _ = try move(item.url, into: folder)
                }
                done += 1
            } catch {
                log.error("Couldn't tidy \(item.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        store.forget(old.map(\.url))
        log.notice("Tidied \(done) old captures (\(Settings.tidyAction.rawValue, privacy: .public))")
    }

    // MARK: Desktop

    /// Offers to move every screenshot and recording off the Desktop into the library.
    static func offerToClearDesktop(store: ShotStore) {
        let loose = looseCaptures(in: Prefs.desktop)
        NSApp.activate()
        let alert = NSAlert()
        guard !loose.isEmpty else {
            alert.messageText = "No screenshots on your Desktop"
            alert.informativeText = "Nothing to move."
            alert.runModal()
            return
        }
        let dest = root.appendingPathComponent("From Desktop", isDirectory: true)
        alert.messageText = "Move \(loose.count) screenshot\(loose.count == 1 ? "" : "s") off your Desktop?"
        alert.informativeText = "They'll go into Pictures › Stackshot › From Desktop. Only screenshots and screen recordings move, nothing else."
        alert.addButton(withTitle: "Move \(loose.count)")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var moved: [URL: URL] = [:]
        for item in loose {
            if let to = try? move(item.url, into: dest) { moved[item.url.standardizedFileURL] = to }
        }
        store.relocate(moved)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }
}

// MARK: - Remembering the stack

/// Saves which files are on the stack (and recently dismissed) so a restart or update doesn't lose them.
@MainActor
enum StackMemory {
    private static let shotsKey = "stack.shots"
    private static let recentKey = "stack.recent"

    static func save(_ store: ShotStore) {
        UserDefaults.standard.set(store.shots.map(\.url.path), forKey: shotsKey)
        UserDefaults.standard.set(store.recent.map(\.url.path), forKey: recentKey)
    }

    static func restore(into store: ShotStore) {
        let paths = UserDefaults.standard.stringArray(forKey: shotsKey) ?? []
        let recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        store.restoreSaved(
            shots: paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) },
            recent: recent.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        )
    }
}
