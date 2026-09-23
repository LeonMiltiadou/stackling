import AppKit
import ServiceManagement

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--uninstall") {
        Uninstall.run()
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

/// Undoes everything Stackshot changed on this Mac. Called by scripts/uninstall.sh.
@MainActor
enum Uninstall {
    static func run() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            print("• Removed Stackshot from Login Items")
        }
        Prefs.restoreOriginals()
        print("• Put the macOS screenshot settings back the way they were")
        NativeShortcuts.restoreOriginal()
        print("• Gave ⇧⌘4 back to macOS")
    }
}
