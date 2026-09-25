import Foundation
import Testing
@testable import StacklingKit

@Suite struct SettingsTests {
    @Test func registeredDefaultsMatchTheFirstLaunchExperience() throws {
        let name = "StacklingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        AppSettings.registerDefaults(in: defaults)
        #expect(defaults.double(forKey: DefaultsKey.shrinkDelay) == 2)
        #expect(defaults.integer(forKey: DefaultsKey.tidyAfterDays) == 7)
        #expect(defaults.string(forKey: DefaultsKey.tidyAction) == Library.TidyAction.archive.rawValue)
        #expect(defaults.bool(forKey: DefaultsKey.takeOverArea))
        #expect(!defaults.bool(forKey: DefaultsKey.copyOnCapture))
        #expect(!defaults.bool(forKey: DefaultsKey.keepNativeThumbnail))
    }

    @Test func captureShortcutsReadLikeTheMenu() {
        #expect(HotKeys.Key.allCases.map(\.label) == ["⇧⌘4", "⇧⌘8", "⇧⌘9", "⇧⌘7"])
    }

    @MainActor @Test func cardKeysThatDoTheSameThingShareARow() {
        let rows = CardKeys.reference
        #expect(rows.map(\.keys) == ["⌘C", "Space  or  E", "T", "P", "G", "Esc", "⌘⌫"])
        #expect(rows[1].summary == "Edit, or preview a recording")
    }

    @MainActor @Test func cardKeyIdsAreUniqueAndClearOfTheCaptureKeys() {
        let ids = CardKeys.bindings.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids).isDisjoint(with: HotKeys.Key.allCases.map(\.id)))
    }
}
