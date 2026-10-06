import AppKit

/// Everything Stackling opens outside the stack asks `allows` first: its own windows, other apps, Finder,
/// the share sheet, open and save panels, name prompts and alerts, System Settings and capture overlays.
/// (What's inside one of its windows is covered by that window's own gate.) Stackling Dev and the tests
/// make it inert, so a press that lands on the wrong card can never put anything on your screen; it only
/// notes what would have opened.
@MainActor
enum Outside {
    private(set) static var isInert = false
    /// What would have opened while inert, oldest first.
    private(set) static var blocked: [String] = []

    static func makeInert() {
        guard !isInert else { return }
        isInert = true
        Log.app.notice("outside.inert")
    }

    /// Whether `what` may open now ("editor", "preview-app", "finder"…). While inert it says no and notes it.
    static func allows(_ what: String) -> Bool {
        guard isInert else { return true }
        blocked.append(what)
        Log.actions.notice("outside.blocked what=\(what, privacy: .public)")
        return false
    }

    /// Shows an error as an alert, the usual fallback when an action fails.
    static func alert(_ error: Error) {
        guard allows("alert") else { return }
        NSAlert(error: error).runModal()
    }

    /// Runs `body` with the openers live, then makes them inert again. Only for the test that Stackling
    /// Dev refuses to start without them, and `body` must not open anything.
    static func whileLive<T>(_ body: () -> T) -> T {
        isInert = false
        defer { isInert = true }
        return body()
    }
}
