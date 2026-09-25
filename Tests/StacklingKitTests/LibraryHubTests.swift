import AppKit
import Foundation
import Testing
@testable import StacklingKit

@MainActor
@Suite struct LibraryHubTests {
    private let now = Date()
    private func item(_ name: String, _ kind: LibraryIndex.Item.Kind = .still, folder: String? = nil, daysAgo: Double = 0) -> LibraryIndex.Item {
        LibraryIndex.Item(url: URL(fileURLWithPath: "/L/\(folder.map { $0 + "/" } ?? "")\(name)"), kind: kind,
                          created: now.addingTimeInterval(-daysAgo * 86_400), folder: folder)
    }

    @Test func sectionsSortShotsSensibly() {
        let fresh = item("a.png"), old = item("b.png", daysAgo: 10), video = item("c.mov", .video)
        let archived = item("d.png", folder: "Archive/2026-09"), filed = item("e.png", folder: "Bugs/Checkout")
        #expect(LibrarySection.recent.contains(fresh, now: now))
        #expect(!LibrarySection.recent.contains(old, now: now))
        #expect(LibrarySection.recordings.contains(video))
        #expect(!LibrarySection.screenshots.contains(video))
        #expect(!LibrarySection.screenshots.contains(archived), "the archive stays out of the everyday sections")
        #expect(LibrarySection.archive.contains(archived))
        #expect(LibrarySection.all.contains(archived))
        #expect(LibrarySection.folder("Bugs").contains(filed), "a folder includes its subfolders")
        #expect(!LibrarySection.folder("Bug").contains(filed))
    }

    @Test func kindsComeFromTheFileType() {
        #expect(LibraryIndex.kind(of: URL(fileURLWithPath: "/x.gif")) == .gif)
        #expect(LibraryIndex.kind(of: URL(fileURLWithPath: "/x.MOV")) == .video)
        #expect(LibraryIndex.kind(of: URL(fileURLWithPath: "/x.heic")) == .still)
        #expect(LibraryIndex.kind(of: URL(fileURLWithPath: "/x.txt")) == nil)
    }

    @Test func folderPathsAreRelativeToTheLibrary() {
        let root = URL(fileURLWithPath: "/L")
        #expect(LibraryIndex.folderPath(of: URL(fileURLWithPath: "/L/a.png"), in: root) == nil)
        #expect(LibraryIndex.folderPath(of: URL(fileURLWithPath: "/L/Archive/2026-09/a.png"), in: root) == "Archive/2026-09")
    }

    @Test func searchNeedsEveryWordSomewhere() {
        let shot = item("checkout-summary-crash.png", folder: "Bugs")
        SearchIndex.shared.remember("TypeError: cart.total is undefined", for: shot.url)
        #expect(SearchIndex.shared.matches(shot, query: "cart.total"))
        #expect(SearchIndex.shared.matches(shot, query: "TYPEERROR bugs"), "case doesn't matter, and folders count")
        #expect(SearchIndex.shared.matches(shot, query: "checkout crash"))
        #expect(!SearchIndex.shared.matches(shot, query: "cart dashboard"))
        #expect(SearchIndex.shared.matches(shot, query: "   "))
    }

    @Test func readsWordsFromARealImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")
        let image = NSImage(size: NSSize(width: 700, height: 120), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Payment failed: card declined" as NSString).draw(at: NSPoint(x: 20, y: 44), withAttributes: [.font: NSFont.systemFont(ofSize: 34)])
            return true
        }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        let text = SearchIndex.readText(at: url).lowercased()
        #expect(text.contains("payment failed"))
        #expect(text.contains("declined"))
    }
}
