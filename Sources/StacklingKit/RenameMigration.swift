import AppKit

/// Stackling used to be called Stackshot. The first launch under the new name carries everything
/// across: settings (including the backups of system settings that uninstalling relies on), the
/// library folder, and the saved stack. Edits files are renamed as they're first opened (see `Markup`).
@MainActor
enum RenameMigration {
    nonisolated static let legacyBundleID = "com.leonmiltiadou.stackshot"
    nonisolated static let legacySidecarExtension = "stackshot"
    /// Permissions belong to each app, so "we've already asked" can't carry across: Stackling has to ask for itself.
    nonisolated static let perAppKeys: Set<String> = [DefaultsKey.askedScreenRecording]

    static var legacyLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Stackshot", isDirectory: true)
    }

    /// Runs once. Call before `AppSettings.registerDefaults()`, so registered defaults
    /// don't hide which settings still need copying.
    static func runIfNeeded(defaults d: UserDefaults = .standard) {
        guard !d.bool(forKey: DefaultsKey.migratedFromStackshot) else { return }
        d.set(true, forKey: DefaultsKey.migratedFromStackshot)
        let copied = copySettings(into: d)
        moveLibrary(defaults: d)
        Log.app.notice("rename.done settings-copied=\(copied)")
    }

    /// Copies every setting the old app saved, without overwriting anything already saved under the new name.
    /// `domainName` is the new app's own domain: only what's saved there counts, not registered defaults.
    @discardableResult
    static func copySettings(into d: UserDefaults, domainName: String? = Bundle.main.bundleIdentifier, from domain: String = legacyBundleID) -> Int {
        let app = domain as CFString
        guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty,
              let values = CFPreferencesCopyMultiple(keys as CFArray, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        else { return 0 }
        let saved = domainName.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        var copied = 0
        for (key, value) in values where saved[key] == nil && !perAppKeys.contains(key) {
            d.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// Renames ~/Pictures/Stackshot to ~/Pictures/Stackling, and points the save folder and the saved
    /// stack at the new place.
    private static func moveLibrary(defaults d: UserDefaults) {
        let old = legacyLibrary, new = Library.root
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        // Checked before the move: once the old folder is gone, the save folder reads as the Desktop.
        let wasSavingThere = ScreenshotPrefs.screenshotFolder.standardizedFileURL == old.standardizedFileURL
        guard !fm.fileExists(atPath: new.path) else {
            Log.library.notice("rename.library-skipped reason=both-folders-exist")
            return
        }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            Log.library.error("rename.library-failed error=\(error.localizedDescription, privacy: .public)")
            return
        }
        if wasSavingThere { ScreenshotPrefs.setScreenshotFolder(new) }
        for key in [DefaultsKey.stackShots, DefaultsKey.stackRecent] {
            let paths = d.stringArray(forKey: key) ?? []
            d.set(paths.map { rebase($0, from: old.path, to: new.path) }, forKey: key)
        }
        Log.library.notice("rename.library-moved to=\(new.path, privacy: .public) save-folder-updated=\(wasSavingThere)")
    }

    /// `path` moved from under `old` to under `new`; anything elsewhere is left as it is.
    static func rebase(_ path: String, from old: String, to new: String) -> String {
        path == old || path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path
    }
}
