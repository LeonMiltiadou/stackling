import AppKit
import Foundation
import Testing
@testable import StackshotKit

@Suite struct ClaudeCodeTests {
    @Test func readsSuggestionsFromTheJSONEnvelope() throws {
        let json = """
        {"type":"result","is_error":false,"result":"","structured_output":{"files":[
          {"file":"Screenshot 1.png","name":"checkout-null-error","folder":"Bugs","reason":"Stack trace in checkout"}]}}
        """
        let suggestions = try ClaudeCode.decode(Data(json.utf8))
        #expect(suggestions == [ClaudeCode.Suggestion(file: "Screenshot 1.png", name: "checkout-null-error", folder: "Bugs", reason: "Stack trace in checkout")])
    }

    @Test func reportsClaudeErrors() {
        let json = #"{"is_error":true,"result":"Not logged in"}"#
        #expect(throws: ClaudeCode.Failure.self) { try ClaudeCode.decode(Data(json.utf8)) }
    }

    @Test func rejectsOutputThatIsntJSON() {
        #expect(throws: ClaudeCode.Failure.self) { try ClaudeCode.decode(Data("Error: something".utf8)) }
    }

    @Test func promptListsFilesAndExistingFolders() {
        let prompt = ClaudeCode.prompt(for: [URL(fileURLWithPath: "/x/Screenshot A.png")], existingFolders: ["Bugs", "Design"])
        #expect(prompt.contains("- Screenshot A.png"))
        #expect(prompt.contains("- Bugs"))
        #expect(prompt.contains("- Design"))
    }

    /// Real call to Claude Code. Costs a few cents, so it only runs when asked:
    /// STACKSHOT_LIVE_CLAUDE=1 swift test --filter ClaudeCodeTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STACKSHOT_LIVE_CLAUDE"] == "1"))
    func namesARealScreenshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot 2026-09-25 at 10.00.00.png")
        try Self.image(saying: "TypeError: Cannot read properties of undefined (reading 'total') at Checkout.submit").write(to: file)

        let suggestions = try await ClaudeCode.suggest(for: [file], in: dir, existingFolders: ["Bugs", "Design"], model: "haiku")
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.file == file.lastPathComponent)
        #expect(suggestions.first?.folder == "Bugs")
    }

    private static func image(saying text: String) -> Data {
        let image = NSImage(size: NSSize(width: 900, height: 120), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)])
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
