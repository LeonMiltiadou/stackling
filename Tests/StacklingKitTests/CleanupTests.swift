import Foundation
import Testing
@testable import StacklingKit

struct CleanupTests {
    let taken = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let day: TimeInterval = 86_400

    private func plan(_ note: UsageNote, edited: Bool = false, used: Int = 3, untouched: Int = 14) -> Cleanup.Plan? {
        Cleanup.plan(note: note, created: taken, edited: edited, usedDays: used, untouchedDays: untouched)
    }

    @Test func untouchedShotsGoAfterTwoWeeks() {
        #expect(plan(UsageNote()) == .init(date: taken + 14 * day, reason: .untouched))
    }

    @Test func usedShotsGoThreeDaysAfterTheirLastUse() {
        let lastUse = taken + 5 * day
        #expect(plan(UsageNote(uses: 2, lastUsed: lastUse)) == .init(date: lastUse + 3 * day, reason: .used))
    }

    @Test func keptAndEditedShotsStay() {
        #expect(plan(UsageNote(uses: 1, lastUsed: taken, keep: true)) == nil)
        #expect(plan(UsageNote(), edited: true) == nil)
    }

    @Test func zeroDaysMeansNever() {
        #expect(plan(UsageNote(), untouched: 0) == nil)
        #expect(plan(UsageNote(uses: 1, lastUsed: taken), used: 0) == nil)
    }

    @Test func saysWhenInPlainWords() {
        let now = Date()
        #expect(Cleanup.when(now, now: now) == "today")
        #expect(Cleanup.when(now + day, now: now) == "tomorrow")
        #expect(Cleanup.when(now + 3 * day, now: now) == "in 3 days")
    }

    @Test func theNoteLivesOnTheFileAndMovesWithIt() throws {
        let folder = try TempFolder()
        let shot = try folder.file("Screenshot a.png")
        #expect(Usage.read(shot) == UsageNote())

        Usage.used(shot, how: "copy", at: taken)
        Usage.used(shot, how: "drag", at: taken + day)
        Usage.noteSource(CaptureSource(app: "Terminal", window: "zsh"), for: shot)
        Usage.setKeep(shot, true)

        let moved = folder.url.appendingPathComponent("Renamed.png")
        try FileManager.default.moveItem(at: shot, to: moved)
        #expect(Usage.read(moved) == UsageNote(uses: 2, lastUsed: taken + day, keep: true, app: "Terminal", window: "zsh"))
    }
}

struct LibraryTileTests {
    @Test func defaultNamesDropTheDate() {
        func item(_ name: String) -> LibraryIndex.Item {
            LibraryIndex.Item(url: URL(fileURLWithPath: "/x/\(name).png"), kind: .still, created: Date(), folder: nil)
        }
        #expect(item("Screenshot 2026-09-25 at 15.49.57").shortName == "Screenshot 15.49.57")
        #expect(item("Screen Recording 2026-09-25 at 09.01.02 (2)").shortName == "Screen Recording 09.01.02 (2)")
        #expect(item("checkout-bug").shortName == "checkout-bug")
    }
}

@MainActor
struct HideSecretsMessageTests {
    @Test func saysWhatHappenedPlainly() {
        typealias R = EditorModel.SecretsResult
        #expect(R.unreadable.message == "Couldn't read the text")
        #expect(R.done(hidden: 0, leftAsExamples: 0).message == "None found")
        #expect(R.done(hidden: 0, leftAsExamples: 2).message == "None hidden · 2 looked like examples")
        #expect(R.done(hidden: 3, leftAsExamples: 0).message == "Hid 3")
        #expect(R.done(hidden: 2, leftAsExamples: 1).message == "Hid 2 · 1 left (looked like examples)")
    }
}
