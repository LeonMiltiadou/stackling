import AppKit

/// macOS's Screen Recording permission, which Stackling needs to freeze the screen itself.
@MainActor
enum ScreenCapturePermission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// True when Stackling may capture the screen. The first time, asks macOS to show its own prompt;
    /// after that, explains where to turn it on.
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
        To freeze the screen and take screenshots itself, turn on Stackling in System Settings → Privacy & Security → Screen & System Audio Recording. Then quit and reopen Stackling.

        Until then, the Mac's own ⇧⌘3 and ⇧⌘5 still land on the stack.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL)
        }
        return false
    }
}
