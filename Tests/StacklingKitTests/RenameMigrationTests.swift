import Foundation
import Testing
@testable import StacklingKit

@MainActor
@Suite struct RenameMigrationTests {
    @Test func rebasesPathsInsideTheOldLibraryOnly() {
        let old = "/Users/x/Pictures/Stackshot", new = "/Users/x/Pictures/Stackling"
        #expect(RenameMigration.rebase("/Users/x/Pictures/Stackshot/Bugs/a.png", from: old, to: new) == "/Users/x/Pictures/Stackling/Bugs/a.png")
        #expect(RenameMigration.rebase("/Users/x/Pictures/Stackshot", from: old, to: new) == new)
        #expect(RenameMigration.rebase("/Users/x/Pictures/Stackshots/a.png", from: old, to: new) == "/Users/x/Pictures/Stackshots/a.png")
        #expect(RenameMigration.rebase("/Users/x/Desktop/a.png", from: old, to: new) == "/Users/x/Desktop/a.png")
    }

    @Test func copiesOldSettingsWithoutOverwritingNewOnes() throws {
        let oldDomain = "io.github.stackling.tests.old-\(UUID().uuidString)"
        let newSuite = "io.github.stackling.tests.new-\(UUID().uuidString)"
        let app = oldDomain as CFString
        CFPreferencesSetAppValue("tidyAfterDays" as CFString, 30 as CFNumber, app)
        CFPreferencesSetAppValue("original.location" as CFString, "__unset__" as CFString, app)
        CFPreferencesSetAppValue("copyOnCapture" as CFString, kCFBooleanTrue, app)
        CFPreferencesSetAppValue("askedScreenRecording" as CFString, kCFBooleanTrue, app)
        CFPreferencesAppSynchronize(app)
        let defaults = try #require(UserDefaults(suiteName: newSuite))
        defer {
            defaults.removePersistentDomain(forName: newSuite)
            for key in ["tidyAfterDays", "original.location", "copyOnCapture", "askedScreenRecording"] { CFPreferencesSetAppValue(key as CFString, nil, app) }
            CFPreferencesAppSynchronize(app)
        }
        defaults.set(false, forKey: "copyOnCapture")

        let copied = RenameMigration.copySettings(into: defaults, domainName: newSuite, from: oldDomain)

        #expect(copied == 2)
        #expect(defaults.integer(forKey: "tidyAfterDays") == 30)
        #expect(defaults.string(forKey: "original.location") == "__unset__")
        #expect(defaults.bool(forKey: "copyOnCapture") == false)
        #expect(defaults.object(forKey: "askedScreenRecording") == nil)
    }

    @Test func oldEditsFilesAreFoundUnderTheNewName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("Screenshot 1.png")
        var markup = Markup()
        markup.items.append(Annotation(tool: .rect, points: [.zero, CGPoint(x: 10, y: 10)], color: RGBA.palette[0], width: 4))
        let legacy = dir.appendingPathComponent(".Screenshot 1.png.stackshot")
        try JSONEncoder().encode(markup).write(to: legacy)

        #expect(Markup.load(for: image) == markup)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: Markup.sidecarURL(for: image).path))
    }
}
