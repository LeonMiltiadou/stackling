import Foundation
import Testing
@testable import StackshotKit

@Suite struct FilesTests {
    @Test func freeURLAddsANumberWhenTaken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CaptureFile.freeURL(for: "a.png", in: dir).lastPathComponent == "a.png")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.png").path, contents: Data())
        #expect(CaptureFile.freeURL(for: "a.png", in: dir).lastPathComponent == "a (2).png")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (2).png").path, contents: Data())
        #expect(CaptureFile.freeURL(for: "a.png", in: dir).lastPathComponent == "a (3).png")
    }

    @Test func newURLUsesTheMacOSNamingStyle() {
        let date = DateComponents(calendar: .current, year: 2026, month: 9, day: 25, hour: 11, minute: 52, second: 22).date!
        let url = CaptureFile.newURL(.recording, ext: "mov", in: FileManager.default.temporaryDirectory, at: date)
        #expect(url.lastPathComponent == "Screen Recording 2026-09-25 at 11.52.22.mov")
    }

    @Test func capturesAreRecognisedByName() {
        #expect(CaptureFile.isCapture(URL(fileURLWithPath: "/nope/Screenshot 2026-09-25 at 11.52.22.png")))
        #expect(!CaptureFile.isCapture(URL(fileURLWithPath: "/nope/holiday.png")))
    }

    @Test func durationsReadLikeAClock() {
        #expect(formatDuration(7) == "0:07")
        #expect(formatDuration(754) == "12:34")
        #expect(formatDuration(-3) == "0:00")
    }

    @Test func squareConstraintKeepsTheDragDirection() {
        #expect(squareConstrained(from: .zero, to: CGPoint(x: 10, y: -4)) == CGPoint(x: 10, y: -10))
    }
}
