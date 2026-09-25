import Foundation
import Testing
@testable import StacklingKit

@MainActor
@Suite struct ImporterTests {
    @Test func acceptsPicturesVideosAndPDFs() {
        for name in ["a.png", "b.JPG", "c.heic", "d.gif", "e.pdf", "f.mov", "g.mp4"] {
            #expect(Importer.isSupported(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
        for name in ["notes.txt", "archive.zip", "app.dmg", "noext"] {
            #expect(!Importer.isSupported(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }

    @Test func addsOnlySupportedFilesAndLeavesThemWhereTheyAre() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("photo from slack.png")
        let notes = dir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: photo.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        FileManager.default.createFile(atPath: notes.path, contents: Data("hi".utf8))

        let added = Importer.add([photo, notes], from: "test")

        #expect(added == 1)
        #expect(ShotStore.shared.shots.first?.url == photo)
        #expect(FileManager.default.fileExists(atPath: photo.path))
        ShotStore.shared.dismiss(ShotStore.shared.shots.first!)
    }

    @Test func pastedImagesAreNamedLikeCaptures() {
        let url = CaptureFile.newURL(.pasted, ext: "png", in: FileManager.default.temporaryDirectory)
        #expect(url.lastPathComponent.hasPrefix("Pasted Image "))
        #expect(CaptureFile.isCapture(url))
    }
}
