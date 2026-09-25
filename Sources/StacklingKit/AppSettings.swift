import Foundation

/// Every UserDefaults key Stackling uses, in one place.
enum DefaultsKey {
    static let jevAutoFile = "jev.autoFile"
    static let jevCheckSecrets = "jev.checkSecrets"
    static let jevSpotJunk = "jev.spotJunk"
    static let jevDescribePictures = "jev.describePictures"
    static let migratedFromStackshot = "rename.fromStackshot"
    static let claudeModel = "claudeModel"
    static let showKeystrokes = "showKeystrokes"
    static let shrinkDelay = "fadeDelay"            // stored under its old name so existing choices carry over
    static let copyOnCapture = "copyOnCapture"
    /// Days before an untouched loose shot is cleared (the key predates "used" shots having their own).
    static let tidyAfterDays = "tidyAfterDays"
    static let cleanupUsedDays = "cleanupUsedDays"
    static let tidyAction = "tidyAction"
    static let takeOverArea = "takeOverArea"
    static let keepNativeThumbnail = "leaveNativeThumbnail"
    static let welcomed = "welcomed.v2"
    static let libraryAdopted = "library.adopted"
    static let askedScreenRecording = "askedScreenRecording"
    static let stackShots = "stack.shots"
    static let stackRecent = "stack.recent"
    static let settingsTab = "settings.tab"

    /// Where we keep a system setting's value from before Stackling first changed it.
    static func original(_ name: String) -> String { "original.\(name)" }
}

/// Stackling's own settings. System settings it changes live in `ScreenshotPrefs` and `NativeShortcuts`.
enum AppSettings {
    private static var d: UserDefaults { .standard }

    /// Defaults for settings that aren't simply false or zero. Takes a store so tests can use a throwaway one.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            DefaultsKey.shrinkDelay: 2.0,
            DefaultsKey.tidyAfterDays: 14,
            DefaultsKey.cleanupUsedDays: 3,
            DefaultsKey.tidyAction: Library.TidyAction.trash.rawValue,
            DefaultsKey.takeOverArea: true,
        ])
    }

    /// Seconds of quiet before the stack shrinks into a little box. 0 means never.
    static var shrinkDelay: Double {
        get { d.double(forKey: DefaultsKey.shrinkDelay) }
        set { d.set(newValue, forKey: DefaultsKey.shrinkDelay) }
    }

    /// Also put every new capture on the clipboard.
    static var copyOnCapture: Bool {
        get { d.bool(forKey: DefaultsKey.copyOnCapture) }
        set { d.set(newValue, forKey: DefaultsKey.copyOnCapture) }
    }

    /// Days before loose captures in the inbox get tidied away. 0 means never.
    /// Days before a loose shot you never used is cleared. 0 means never.
    static var cleanupUntouchedDays: Int {
        get { d.integer(forKey: DefaultsKey.tidyAfterDays) }
        set { d.set(newValue, forKey: DefaultsKey.tidyAfterDays) }
    }

    /// Days after its last copy or drag before a loose shot is cleared. 0 means never.
    static var cleanupUsedDays: Int {
        get { d.integer(forKey: DefaultsKey.cleanupUsedDays) }
        set { d.set(newValue, forKey: DefaultsKey.cleanupUsedDays) }
    }

    static var tidyAction: Library.TidyAction {
        get { Library.TidyAction(rawValue: d.string(forKey: DefaultsKey.tidyAction) ?? "") ?? .trash }
        set { d.set(newValue.rawValue, forKey: DefaultsKey.tidyAction) }
    }

    /// Stackling handles ⇧⌘4 (frozen screen, loupe) instead of macOS.
    static var takeOverArea: Bool {
        get { d.bool(forKey: DefaultsKey.takeOverArea) }
        set { d.set(newValue, forKey: DefaultsKey.takeOverArea) }
    }

    /// You turned the macOS floating thumbnail back on, so don't switch it off at launch.
    static var keepNativeThumbnail: Bool {
        get { d.bool(forKey: DefaultsKey.keepNativeThumbnail) }
        set { d.set(newValue, forKey: DefaultsKey.keepNativeThumbnail) }
    }

    /// Which Claude model Tidy with Claude uses: "haiku", "sonnet" or "opus".
    static var claudeModel: String {
        get { d.string(forKey: DefaultsKey.claudeModel) ?? "sonnet" }
        set { d.set(newValue, forKey: DefaultsKey.claudeModel) }
    }

    /// Jev: file each new capture into the folder it belongs in.
    static var jevAutoFile: Bool {
        get { d.bool(forKey: DefaultsKey.jevAutoFile) }
        set { d.set(newValue, forKey: DefaultsKey.jevAutoFile) }
    }

    /// Jev: double-check what Hide Secrets finds, so examples and placeholders stay readable.
    static var jevCheckSecrets: Bool {
        get { d.bool(forKey: DefaultsKey.jevCheckSecrets) }
        set { d.set(newValue, forKey: DefaultsKey.jevCheckSecrets) }
    }

    /// Jev: suggest throwaway shots for the Trash when tidying.
    /// Lets a vision model describe shots with next to no words, so auto-filing can place them. Sends the picture.
    static var jevDescribePictures: Bool {
        get { d.bool(forKey: DefaultsKey.jevDescribePictures) }
        set { d.set(newValue, forKey: DefaultsKey.jevDescribePictures) }
    }

    static var jevSpotJunk: Bool {
        get { d.bool(forKey: DefaultsKey.jevSpotJunk) }
        set { d.set(newValue, forKey: DefaultsKey.jevSpotJunk) }
    }

    /// Show the shortcuts you press, as key caps, in area and full-screen recordings.
    static var showKeystrokes: Bool {
        get { d.bool(forKey: DefaultsKey.showKeystrokes) }
        set { d.set(newValue, forKey: DefaultsKey.showKeystrokes) }
    }

    /// The welcome alert has been shown, so later launches stay quiet.
    static var hasSeenWelcome: Bool {
        get { d.bool(forKey: DefaultsKey.welcomed) }
        set { d.set(newValue, forKey: DefaultsKey.welcomed) }
    }

    /// The one-time switch from saving on the Desktop to the library has been considered.
    static var libraryAdopted: Bool {
        get { d.bool(forKey: DefaultsKey.libraryAdopted) }
        set { d.set(newValue, forKey: DefaultsKey.libraryAdopted) }
    }
}
