import AppKit
import ServiceManagement

/// The app's front door. `main.swift` only calls `StacklingApp.run()`, so everything else can live in
/// StacklingKit, where the tests can reach it.
public enum StacklingApp {
    @MainActor
    public static func run() {
        if CommandLine.arguments.contains("--uninstall") {
            Uninstall.run()
            exit(0)
        }
        // `Stackling --save-jev-key < key.txt`: saves a Jev key for scripts and setup. It comes in on
        // standard input, not as an argument, so it never shows up in the process list. Saved by the app
        // itself, so the Keychain treats it as Stackling's and never asks you to allow it.
        if CommandLine.arguments.contains("--save-jev-key") {
            let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            exit(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && JevKey.save(key) ? 0 : 1)
        }
        RenameMigration.runIfNeeded()
        AppSettings.registerDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.app.info("launch version=\(version, privacy: .public)")
        ActivityLog.recordLaunch(version: version)
        app.run()
    }
}

/// Undoes everything Stackling changed on this Mac. Called by scripts/uninstall.sh.
@MainActor
enum Uninstall {
    static func run() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            print("• Removed Stackling from Login Items")
        }
        ScreenshotPrefs.restoreOriginals()
        print("• Put the macOS screenshot settings back the way they were")
        NativeShortcuts.restoreOriginal()
        print("• Gave ⇧⌘4 back to macOS")
    }
}
