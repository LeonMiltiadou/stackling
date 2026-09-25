import AppKit

/// macOS's Screen Recording permission, which Stackling needs to freeze the screen itself.
@MainActor
enum ScreenCapturePermission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// True when Stackling may capture the screen. The first time, asks macOS to show its own prompt;
    /// after that, explains where to turn it on.
    /// Puts Stackling in the Screen Recording list and opens that page of System Settings.
    static func openSettings() {
        // Asking is what puts Stackling in the list; without it there'd be nothing to switch on.
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(settingsURL)
    }

    /// macOS only applies the permission to a fresh process, so: quit, and open again a moment later.
    static func relaunch() {
        Log.app.notice("relaunch reason=screen-recording")
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !UserDefaults.standard.bool(forKey: DefaultsKey.askedScreenRecording) {
            UserDefaults.standard.set(true, forKey: DefaultsKey.askedScreenRecording)
            Log.app.notice("permission.screen-recording.requested")
            CGRequestScreenCaptureAccess()
            return false
        }
        Log.app.notice("permission.screen-recording.missing")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Stackling needs Screen Recording permission"
        alert.informativeText = """
        To freeze the screen and take screenshots itself, turn on Stackling in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Stackling.

        Until then, the Mac's own ⇧⌘3, ⇧⌘4 and ⇧⌘5 still land on the stack.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Reopen Stackling")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
        return false
    }
}
