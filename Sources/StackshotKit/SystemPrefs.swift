import AppKit

/// Reads and writes the system screenshot settings (the `com.apple.screencapture` domain).
enum ScreenshotPrefs {
    private static let domainName = "com.apple.screencapture"
    private static var domain: CFString { domainName as CFString }

    private static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func defaults(_ args: [String]) {
        Shell.run("/usr/bin/defaults", args)
        CFPreferencesAppSynchronize(domain)
    }

    // MARK: Undo support
    // Before we change a system screenshot setting for the first time, we remember what it was,
    // so `--uninstall` can put your Mac back exactly as it was.

    private static let unset = "__unset__"

    private static func backup(_ key: String) {
        let d = UserDefaults.standard
        guard d.object(forKey: DefaultsKey.original(key)) == nil else { return }
        d.set(value(key) ?? unset, forKey: DefaultsKey.original(key))
    }

    static func restoreOriginals() {
        for key in ["show-thumbnail", "location"] {
            switch UserDefaults.standard.object(forKey: DefaultsKey.original(key)) {
            case let s as String where s == unset:
                defaults(["delete", domainName, key])
            case let s as String:
                defaults(["write", domainName, key, "-string", s])
            case let n as NSNumber:
                defaults(["write", domainName, key, "-bool", n.boolValue ? "true" : "false"])
            default:
                // No backup: we only ever touch show-thumbnail without one (early builds), and macOS's default is on.
                if key == "show-thumbnail" { defaults(["delete", domainName, key]) }
            }
        }
    }

    static var desktop: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop") }

    /// Where macOS saves screenshots. Defaults to the Desktop.
    static var screenshotFolder: URL {
        if let raw = value("location") as? String, !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return desktop
    }

    static func setScreenshotFolder(_ url: URL) {
        Log.library.info("save-folder.set path=\(url.path, privacy: .public)")
        backup("location")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defaults(["write", domainName, "location", "-string", url.path])
    }

    /// The little floating thumbnail macOS shows after a capture. We turn it off,
    /// otherwise files only land on disk once it slides away, and you'd see two previews.
    static var nativeThumbnailEnabled: Bool {
        (value("show-thumbnail") as? Bool) ?? true
    }

    static func setNativeThumbnail(_ enabled: Bool) {
        Log.app.info("native-thumbnail.set enabled=\(enabled)")
        backup("show-thumbnail")
        defaults(["write", domainName, "show-thumbnail", "-bool", enabled ? "true" : "false"])
    }
}

/// Switches the Mac's own ⇧⌘4 on or off so Stackshot's frozen-screen capture can use it.
/// The original setting is backed up first so uninstalling puts it back.
enum NativeShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let areaID = "30" // "Save picture of selected area as a file"
    private static let backupKey = DefaultsKey.original("symbolichotkey30")
    private static let unset = "__unset__"

    private static var all: [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
    }

    static var areaShortcutEnabled: Bool {
        guard let entry = all[areaID] as? [String: Any] else { return true }
        return (entry["enabled"] as? Bool) ?? true
    }

    static func setAreaShortcut(enabled: Bool) {
        var dict = all
        if UserDefaults.standard.object(forKey: backupKey) == nil {
            UserDefaults.standard.set(dict[areaID] ?? unset, forKey: backupKey)
        }
        dict[areaID] = entry(enabled: enabled)
        write(dict)
    }

    /// Puts the setting back exactly as it was before Stackshot touched it.
    static func restoreOriginal() {
        guard let original = UserDefaults.standard.object(forKey: backupKey) else { return }
        var dict = all
        if let s = original as? String, s == unset {
            dict[areaID] = entry(enabled: true)
        } else {
            dict[areaID] = original
        }
        write(dict)
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    private static func entry(enabled: Bool) -> [String: Any] {
        // ⇧⌘4: "4", key code 21, shift+command
        ["enabled": enabled, "value": ["parameters": [52, 21, 1_179_648], "type": "standard"]]
    }

    private static func write(_ dict: [String: Any]) {
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // Tells the system to reload keyboard shortcuts without logging out.
        Shell.run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }
}

/// Opens the Mac's own screenshot toolbar (⇧⌘5), for recording with sound or its other options.
enum SystemScreenshotToolbar {
    static func open() {
        // -p saves using your normal settings, so the file lands in the screenshot folder and reaches the stack.
        Shell.run("/usr/sbin/screencapture", ["-i", "-U", "-p"], wait: false)
    }
}

/// Runs a command-line tool and logs when it can't start or fails.
enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String], wait: Bool = true) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            Log.app.error("shell.launch-failed tool=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
        guard wait else { return true }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Log.app.error("shell.failed tool=\(path, privacy: .public) args=\(arguments.joined(separator: " "), privacy: .public) status=\(process.terminationStatus)")
            return false
        }
        return true
    }
}
