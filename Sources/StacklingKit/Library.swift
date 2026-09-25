import AppKit

/// Where screenshots live, and how they stay tidy.
///
///     ~/Pictures/Stackling/
///         new captures land here (the inbox), cleared out once you're done with them (see `Cleanup`)
///         Archive/2026-09/   where cleared shots go if you pick Archive rather than the Trash
///         <your folders>/    anything you file somewhere is yours and never touched
@MainActor
enum Library {
    nonisolated static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Stackling", isDirectory: true)
    }

    nonisolated static let archiveName = "Archive"
    static var archive: URL { root.appendingPathComponent(archiveName, isDirectory: true) }

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
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && $0.lastPathComponent != archiveName }
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

    /// Asks for a folder name, for filing into. The folder is made when something is filed into it.
    static func askForNewFolder() -> URL? {
        guard let name = askForName(title: "New folder", current: "", button: "Create and File",
                                    detail: "Inside your Stackling library. Anything you file here is kept, never cleared out.") else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Asks for a name and makes the folder straight away.
    static func makeFolder() -> URL? {
        guard let name = askForName(title: "New folder", current: "", button: "Create",
                                    detail: "Inside your Stackling library. Anything you file here is kept, never cleared out.") else { return nil }
        let folder = CaptureFile.freeURL(for: name, in: root)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            LibraryIndex.shared.scheduleRescan()
            Log.library.info("folder.new name=\(folder.lastPathComponent, privacy: .public)")
            return folder
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Renames a folder. Returns where it ended up, or nil if nothing changed.
    @discardableResult
    static func renameFolder(_ folder: URL) -> URL? {
        guard let name = askForName(title: "Rename folder", current: folder.lastPathComponent, button: "Rename"),
              name != folder.lastPathComponent else { return nil }
        let dest = CaptureFile.freeURL(for: name, in: folder.deletingLastPathComponent())
        do {
            try FileManager.default.moveItem(at: folder, to: dest)
            ShotStore.shared.relocateFolder(from: folder, to: dest)
            LibraryIndex.shared.scheduleRescan()
            Log.library.info("folder.rename")
            return dest
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Moves a folder and everything in it to the Trash, after asking.
    static func trashFolder(_ folder: URL) -> Bool {
        let count = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move “\(folder.lastPathComponent)” to the Trash?"
        alert.informativeText = count == 0 ? "It's empty." : "The \(count == 1 ? "shot" : "\(count) shots") inside go too. You can get them back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            LibraryIndex.shared.scheduleRescan()
            Log.library.info("folder.trash count=\(count)")
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// A small prompt for a file or folder name. Slashes and colons become dashes; blank means cancel.
    static func askForName(title: String, current: String, button: String, detail: String? = nil) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = current
        field.placeholderString = "e.g. Checkout bug"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        return name
    }

    /// Whether a file is somewhere inside the library.
    nonisolated static func contains(_ url: URL, root: URL? = nil) -> Bool {
        let base = (root ?? Library.root).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base + "/")
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

    /// Sends one loose capture to the Trash or the monthly Archive.
    static func tidyAway(_ item: (url: URL, created: Date), action: TidyAction) throws {
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
        alert.informativeText = "They'll go into Pictures › Stackling › From Desktop. Only screenshots and screen recordings move, nothing else."
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
