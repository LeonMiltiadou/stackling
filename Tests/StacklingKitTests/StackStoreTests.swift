import Foundation
import Testing
@testable import StacklingKit

/// A folder of empty files that cleans up after itself.
final class TempFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("StacklingTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, created: Date? = nil) throws -> URL {
        let file = url.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        if let created {
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
        }
        return file
    }
}

@MainActor @Suite struct StackStoreTests {
    @Test func newShotsGoOnTopAndDuplicatesAreIgnored() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        let a = try folder.file("Screenshot a.png"), b = try folder.file("Screenshot b.png")
        #expect(store.add(a))
        #expect(store.add(b))
        #expect(!store.add(a))
        #expect(store.shots.map(\.url) == [b, a])
    }

    @Test func addingOpensAShrunkStack() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        store.minimized = true
        store.add(try folder.file("Screenshot a.png"))
        #expect(!store.minimized)
    }

    @Test func dismissingMovesTheShotToRecentAndCollapses() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        store.add(try folder.file("Screenshot a.png"))
        store.add(try folder.file("Screenshot b.png"))
        store.toggleExpanded()
        #expect(store.expanded)
        let top = try #require(store.shots.first)
        store.dismiss(top)
        #expect(store.shots.count == 1)
        #expect(store.recent.first === top)
        #expect(!store.expanded)
    }

    @Test func recentlyDismissedIsCapped() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        for i in 0..<(ShotStore.maxRecent + 5) {
            store.add(try folder.file("Screenshot \(i).png"))
        }
        store.clearAll()
        #expect(store.shots.isEmpty)
        #expect(store.recent.count == ShotStore.maxRecent)
        #expect(store.recent.first?.url.lastPathComponent == "Screenshot \(ShotStore.maxRecent + 4).png")
    }

    @Test func restoringPutsItBackOnTop() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        store.add(try folder.file("Screenshot a.png"))
        let shot = try #require(store.shots.first)
        store.dismiss(shot)
        store.minimized = true
        store.restore(shot)
        #expect(store.shots.first === shot)
        #expect(store.recent.isEmpty)
        #expect(!store.minimized)
    }

    @Test func readdingADismissedFileDropsItFromRecent() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        let a = try folder.file("Screenshot a.png")
        store.add(a)
        store.dismiss(try #require(store.shots.first))
        store.add(a)
        #expect(store.recent.isEmpty)
    }

    @Test func pruneDropsCardsWhoseFileWentAway() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        let a = try folder.file("Screenshot a.png")
        store.add(a)
        store.add(try folder.file("Screenshot b.png"))
        try FileManager.default.removeItem(at: a)
        store.pruneMissing()
        #expect(store.shots.map(\.url.lastPathComponent) == ["Screenshot b.png"])
    }
}
