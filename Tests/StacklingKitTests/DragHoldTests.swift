import Foundation
import Testing
@testable import StacklingKit

/// Auto-filing moves a new shot a second or so after it's taken, which is when you're often dragging it
/// out. The app it's dropped on reads the path it was handed, so filing has to wait until it's done.
@MainActor
@Suite struct DragHoldTests {
    /// A clock that only moves when filing pauses, so the tests never really wait.
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var pauses = 0
    }

    private func newShot(in folder: TempFolder) throws -> (Shot, URL) {
        let url = try folder.file("Screenshot.png")
        return (Shot(url: url), url)
    }

    @Test func doesNotMoveAShotWhileItIsDragged() async throws {
        let folder = try TempFolder()
        let (shot, original) = try newShot(in: folder)
        let bugs = folder.url.appendingPathComponent("Bugs", isDirectory: true)
        let clock = Clock()
        shot.dragStarted(at: clock.now)
        var dropped: Date?

        let filed = await AutoFiler.fileWhenFree(shot, into: bugs, now: { clock.now }, pause: { seconds in
            #expect(FileManager.default.fileExists(atPath: original.path), "the dragged path is still there")
            #expect(shot.url == original)
            clock.pauses += 1
            if clock.pauses == 3 {
                shot.dragEnded(at: clock.now)
                dropped = clock.now
            }
            clock.now += seconds
        })

        #expect(filed)
        #expect(clock.pauses > 3, "kept waiting after the drop while the other app reads the file")
        let drop = try #require(dropped)
        #expect(clock.now >= drop + Shot.afterDrop)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(shot.url.deletingLastPathComponent().standardizedFileURL == bugs.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: shot.url.path))
    }

    @Test func aDragThatNeverEndsDoesNotHoldFilingForever() async throws {
        let folder = try TempFolder()
        let (shot, original) = try newShot(in: folder)
        let bugs = folder.url.appendingPathComponent("Bugs", isDirectory: true)
        let clock = Clock()
        let started = clock.now
        shot.dragStarted(at: started)

        let filed = await AutoFiler.fileWhenFree(shot, into: bugs, now: { clock.now }, pause: { seconds in
            clock.pauses += 1
            clock.now += seconds
        })

        #expect(filed)
        #expect(clock.now >= started + Shot.longestDrag)
        #expect(clock.now < started + Shot.longestDrag + 5)
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func filesAtOnceWhenNothingIsDragged() async throws {
        let folder = try TempFolder()
        let (shot, _) = try newShot(in: folder)
        let bugs = folder.url.appendingPathComponent("Bugs", isDirectory: true)
        let clock = Clock()

        let filed = await AutoFiler.fileWhenFree(shot, into: bugs, now: { clock.now }, pause: { _ in clock.pauses += 1 })

        #expect(filed)
        #expect(clock.pauses == 0)
        #expect(shot.url.deletingLastPathComponent().standardizedFileURL == bugs.standardizedFileURL)
    }
}
