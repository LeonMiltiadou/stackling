import AppKit

/// Reads and writes the system screenshot settings (the `com.apple.screencapture` domain).
enum Prefs {
    private static let domain = "com.apple.screencapture" as CFString

    private static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func defaults(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        CFPreferencesAppSynchronize(domain)
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
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defaults(["write", "com.apple.screencapture", "location", "-string", url.path])
    }

    /// The little floating thumbnail macOS shows after a capture. We turn it off,
    /// otherwise files only land on disk once it slides away, and you'd see two previews.
    static var nativeThumbnailEnabled: Bool {
        (value("show-thumbnail") as? Bool) ?? true
    }

    static func setNativeThumbnail(_ enabled: Bool) {
        defaults(["write", "com.apple.screencapture", "show-thumbnail", "-bool", enabled ? "true" : "false"])
    }
}

enum Capture {
    case area, window, screen, toolbar

    /// Runs the system `screencapture` tool. `-p` saves using your normal settings,
    /// so the file lands in the screenshot folder and the watcher picks it up.
    func run() {
        let args: [String]
        switch self {
        case .area: args = ["-i", "-p"]
        case .window: args = ["-i", "-W", "-p"]
        case .screen: args = ["-p"]
        case .toolbar: args = ["-i", "-U", "-p"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        try? p.run()
    }
}
