import Foundation
import Testing
@testable import StacklingKit

@MainActor @Suite struct LibraryTidyTests {
    let now = Date()
    var weekAgo: Date { now.addingTimeInterval(-7 * 86_400) }
    var cutoff: Date { now.addingTimeInterval(-3 * 86_400) }

    @Test func picksOldCapturesOnly() throws {
        let folder = try TempFolder()
        let old = try folder.file("Screenshot old.png", created: weekAgo)
        try folder.file("Screenshot new.png", created: now)
        try folder.file("holiday.png", created: weekAgo)
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Screenshot folder"), withIntermediateDirectories: true)

        let picked = Library.tidyCandidates(in: folder.url, olderThan: cutoff, sparing: [])
        #expect(picked.map(\.url.lastPathComponent) == [old.lastPathComponent])
    }

    @Test func leavesShotsThatAreStillOnTheStack() throws {
        let folder = try TempFolder()
        let kept = try folder.file("Screenshot kept.png", created: weekAgo)
        let gone = try folder.file("Screen Recording gone.mov", created: weekAgo)

        let picked = Library.tidyCandidates(in: folder.url, olderThan: cutoff, sparing: [kept])
        #expect(picked.map(\.url.lastPathComponent) == [gone.lastPathComponent])
    }

    @Test func movingIntoAFolderPicksAFreeNameAndTakesTheEditsAlong() throws {
        let folder = try TempFolder()
        let dest = folder.url.appendingPathComponent("Filed", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dest.appendingPathComponent("Screenshot a.png").path, contents: Data())
        let shot = try folder.file("Screenshot a.png")
        FileManager.default.createFile(atPath: Markup.sidecarURL(for: shot).path, contents: Data())

        let moved = try Library.move(shot, into: dest)
        #expect(moved.lastPathComponent == "Screenshot a (2).png")
        #expect(FileManager.default.fileExists(atPath: Markup.sidecarURL(for: moved).path))
        #expect(!FileManager.default.fileExists(atPath: Markup.sidecarURL(for: shot).path))
    }
}
