import Foundation

/// Every UserDefaults key Stackshot uses, in one place.
enum DefaultsKey {
    static let shrinkDelay = "fadeDelay"            // stored under its old name so existing choices carry over
    static let copyOnCapture = "copyOnCapture"
    static let tidyAfterDays = "tidyAfterDays"
    static let tidyAction = "tidyAction"
    static let takeOverArea = "takeOverArea"
    static let keepNativeThumbnail = "leaveNativeThumbnail"
    static let welcomed = "welcomed.v2"
    static let libraryAdopted = "library.adopted"
    static let askedScreenRecording = "askedScreenRecording"
    static let stackShots = "stack.shots"
    static let stackRecent = "stack.recent"
    static let settingsTab = "settings.tab"

    /// Where we keep a system setting's value from before Stackshot first changed it.
    static func original(_ name: String) -> String { "original.\(name)" }
}

/// Stackshot's own settings. System settings it changes live in `ScreenshotPrefs` and `NativeShortcuts`.
enum AppSettings {
    private static var d: UserDefaults { .standard }

    /// Defaults for settings that aren't simply false or zero.
    static func registerDefaults() {
        d.register(defaults: [
            DefaultsKey.shrinkDelay: 2.0,
            DefaultsKey.tidyAfterDays: 7,
            DefaultsKey.tidyAction: Library.TidyAction.archive.rawValue,
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
    static var tidyAfterDays: Int {
        get { d.integer(forKey: DefaultsKey.tidyAfterDays) }
        set { d.set(newValue, forKey: DefaultsKey.tidyAfterDays) }
    }

    static var tidyAction: Library.TidyAction {
        get { Library.TidyAction(rawValue: d.string(forKey: DefaultsKey.tidyAction) ?? "") ?? .archive }
        set { d.set(newValue.rawValue, forKey: DefaultsKey.tidyAction) }
    }

    /// Stackshot handles ⇧⌘4 (frozen screen, loupe) instead of macOS.
    static var takeOverArea: Bool {
        get { d.bool(forKey: DefaultsKey.takeOverArea) }
        set { d.set(newValue, forKey: DefaultsKey.takeOverArea) }
    }

    /// You turned the macOS floating thumbnail back on, so don't switch it off at launch.
    static var keepNativeThumbnail: Bool {
        get { d.bool(forKey: DefaultsKey.keepNativeThumbnail) }
        set { d.set(newValue, forKey: DefaultsKey.keepNativeThumbnail) }
    }
}
