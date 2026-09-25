import Foundation
import Testing
@testable import StacklingKit

@MainActor @Suite struct LibraryTidyTests {
    let now = Date()
    var weekAgo: Date { now.addingTimeInterval(-7 * 86_400) }

    @Test func onlyLooseCapturesAreCleanedUp() throws {
        let folder = try TempFolder()
        try folder.file("Screenshot old.png", created: weekAgo)
        try folder.file("holiday.png", created: weekAgo)
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Screenshot folder"), withIntermediateDirectories: true)

        #expect(Library.looseCaptures(in: folder.url).map(\.url.lastPathComponent) == ["Screenshot old.png"])
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
