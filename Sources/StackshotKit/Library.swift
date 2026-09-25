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
        guard !AppSettings.libraryAdopted else { return }
        AppSettings.libraryAdopted = true
        guard ScreenshotPrefs.screenshotFolder.standardizedFileURL == ScreenshotPrefs.desktop.standardizedFileURL else {
            Log.library.notice("adopt.skipped reason=custom-save-folder")
            return
        }
        ScreenshotPrefs.setScreenshotFolder(root)
        Log.library.notice("adopt path=\(root.path, privacy: .public)")
    }

    // MARK: Folders

    /// Folders you've filed shots into, most recently used first.
    static func folders(in libraryRoot: URL? = nil) -> [URL] {
        let root = libraryRoot ?? Library.root
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            Log.library.error("folders.read-failed path=\(root.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && $0.lastPathComponent != "Archive" }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
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
            Log.library.info("file file=\(dest.lastPathComponent, privacy: .public) folder=\(folder.lastPathComponent, privacy: .public)")
            return true
        } catch {
            Log.library.error("file.failed file=\(shot.url.lastPathComponent, privacy: .public) folder=\(folder.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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

    // MARK: Moving files

    /// Moves a file and its sidecar into `folder`, picking a free name. Returns where it ended up.
    static func move(_ url: URL, into folder: URL) throws -> URL {
        let dest = CaptureFile.freeURL(for: url.lastPathComponent, in: folder)
        try move(url, to: dest)
        return dest
    }

    /// Moves a file to exactly `dest`, taking its edits along. A sidecar that won't move is logged, not thrown.
    static func move(_ url: URL, to dest: URL) throws {
        try FileManager.default.moveItem(at: url, to: dest)
        let sidecar = Markup.sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        do {
            try FileManager.default.moveItem(at: sidecar, to: Markup.sidecarURL(for: dest))
        } catch {
            Log.library.error("sidecar.move-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a file's edits once the file itself has gone to the Trash.
    static func deleteSidecar(of url: URL) {
        let sidecar = Markup.sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        do {
            try FileManager.default.removeItem(at: sidecar)
        } catch {
            Log.library.error("sidecar.delete-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Tidy-up

    enum TidyAction: String { case archive, trash }

    private static let secondsPerDay: TimeInterval = 86_400

    /// Screenshots and recordings sitting loose in the inbox (not in any folder you made).
    static func looseCaptures(in folder: URL) -> [(url: URL, created: Date)] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            Log.library.error("list.failed path=\(folder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
        return items.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, CaptureFile.isCapture(url) else { return nil }
            return (url, v.creationDate ?? .distantPast)
        }
    }

    /// The loose captures in `folder` made before `cutoff`, leaving alone anything still on the stack.
    static func tidyCandidates(in folder: URL, olderThan cutoff: Date, sparing onStack: [URL]) -> [(url: URL, created: Date)] {
        let spared = Set(onStack.map(\.standardizedFileURL))
        return looseCaptures(in: folder).filter { $0.created < cutoff && !spared.contains($0.url.standardizedFileURL) }
    }

    /// Archives (or trashes) inbox captures older than the tidy setting. Leaves anything still on the stack alone.
    static func tidy(store: ShotStore) {
        let days = AppSettings.tidyAfterDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * secondsPerDay)
        let old = tidyCandidates(in: ScreenshotPrefs.screenshotFolder, olderThan: cutoff, sparing: store.shots.map(\.url))
        guard !old.isEmpty else {
            Log.library.debug("tidy count=0 days=\(days)")
            return
        }
        let action = AppSettings.tidyAction
        var done = 0
        for item in old {
            do {
                try tidyAway(item, action: action)
                done += 1
            } catch {
                Log.library.error("tidy.failed file=\(item.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        store.forget(old.map(\.url))
        Log.library.notice("tidy count=\(done) failed=\(old.count - done) action=\(action.rawValue, privacy: .public)")
    }

    private static func tidyAway(_ item: (url: URL, created: Date), action: TidyAction) throws {
        switch action {
        case .trash:
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            deleteSidecar(of: item.url)
        case .archive:
            let folder = archive.appendingPathComponent(monthFormatter.string(from: item.created), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try move(item.url, into: folder)
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    // MARK: Desktop

    /// Offers to move every screenshot and recording off the Desktop into the library.
    static func offerToClearDesktop(store: ShotStore) {
        let loose = looseCaptures(in: ScreenshotPrefs.desktop)
        NSApp.activate()
        let alert = NSAlert()
        guard !loose.isEmpty else {
            Log.library.info("clear-desktop count=0")
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
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.library.info("clear-desktop.cancelled count=\(loose.count)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            Log.library.error("clear-desktop.folder-failed path=\(dest.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        var moved: [URL: URL] = [:]
        for item in loose {
            do {
                moved[item.url.standardizedFileURL] = try move(item.url, into: dest)
            } catch {
                Log.library.error("clear-desktop.move-failed file=\(item.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        Log.library.info("clear-desktop count=\(moved.count) failed=\(loose.count - moved.count)")
        store.relocate(moved)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }
}
