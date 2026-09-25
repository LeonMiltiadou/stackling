import Foundation
import Testing
@testable import StacklingKit

@Suite struct GroomPlanTests {
    private let root = URL(fileURLWithPath: "/tmp/stackling-groom-\(UUID().uuidString)")

    @Test func pairsSuggestionsWithTheFilesWeSent() {
        let files = [root.appendingPathComponent("Screenshot A.png"), root.appendingPathComponent("Screenshot B.png")]
        let suggestions = [
            ClaudeCode.Suggestion(file: "Screenshot B.png", name: "pr-review", folder: "PRs", reason: "A pull request"),
            ClaudeCode.Suggestion(file: "Somebody else.png", name: "x", folder: "Y", reason: "Not ours"),
        ]
        let entries = GroomPlan.entries(for: files, suggestions: suggestions)
        #expect(entries.map(\.file.lastPathComponent) == ["Screenshot B.png"])
        #expect(entries.first?.name == "pr-review")
    }

    @Test func namesAreMadeSafeForTheFileSystem() {
        #expect(GroomPlan.cleanName("  ../etc/passwd: nope ") == "-etc-passwd- nope")
        #expect(GroomPlan.cleanName(String(repeating: "a", count: 200)).count == 80)
    }

    @Test func neverFilesIntoTheArchive() {
        #expect(GroomPlan.cleanFolder("archive") == "Archived")
        #expect(GroomPlan.cleanFolder("Bugs") == "Bugs")
    }

    @Test func destinationKeepsTheExtensionAndFolder() {
        let entry = GroomEntry(file: root.appendingPathComponent("Screen Recording 1.mov"), name: "login-flow", folder: "Demos", reason: "")
        #expect(GroomPlan.destination(for: entry, root: root).path == root.appendingPathComponent("Demos/login-flow.mov").path)
    }

    @Test func emptyNameKeepsTheOriginalName() {
        let entry = GroomEntry(file: root.appendingPathComponent("Screenshot 1.png"), name: "", folder: "", reason: "")
        #expect(GroomPlan.destination(for: entry, root: root).lastPathComponent == "Screenshot 1.png")
    }
}
