import AppKit
import ServiceManagement

/// The app's front door. `main.swift` only calls `StackshotApp.run()`, so everything else can live in
/// StackshotKit, where the tests can reach it.
public enum StackshotApp {
    @MainActor
    public static func run() {
        if CommandLine.arguments.contains("--uninstall") {
            Uninstall.run()
            exit(0)
        }
        AppSettings.registerDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        Log.app.info("launch version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev", privacy: .public)")
        app.run()
    }
}

/// Undoes everything Stackshot changed on this Mac. Called by scripts/uninstall.sh.
@MainActor
enum Uninstall {
    static func run() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            print("• Removed Stackshot from Login Items")
        }
        ScreenshotPrefs.restoreOriginals()
        print("• Put the macOS screenshot settings back the way they were")
        NativeShortcuts.restoreOriginal()
        print("• Gave ⇧⌘4 back to macOS")
    }
}
