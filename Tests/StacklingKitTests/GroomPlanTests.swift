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

@Suite struct GroomPathTests {
    @Test func commonFolderIsTheDeepestSharedParent() {
        let files = ["/L/Stackling/Bugs/a.png", "/L/Stackling/Design/b.png", "/L/Stackling/c.png"].map { URL(fileURLWithPath: $0) }
        #expect(ClaudeCode.commonFolder(of: files).path == "/L/Stackling")
    }

    @Test func relativePathsKeepSubfolders() {
        let root = URL(fileURLWithPath: "/L/Stackling")
        #expect(ClaudeCode.relativePath(of: URL(fileURLWithPath: "/L/Stackling/Bugs/a.png"), in: root) == "Bugs/a.png")
        #expect(ClaudeCode.relativePath(of: URL(fileURLWithPath: "/elsewhere/x.png"), in: root) == "/elsewhere/x.png")
    }

    @Test func suggestionsMatchFilesInSubfolders() {
        let root = URL(fileURLWithPath: "/L/Stackling")
        let files = [URL(fileURLWithPath: "/L/Stackling/Bugs/a.png"), URL(fileURLWithPath: "/L/Stackling/Design/a.png")]
        let suggestions = [
            ClaudeCode.Suggestion(file: "Design/a.png", name: "settings", folder: "Design", reason: ""),
            ClaudeCode.Suggestion(file: "Bugs/a.png", name: "crash", folder: "Bugs", reason: ""),
        ]
        let entries = GroomPlan.entries(for: files, suggestions: suggestions, in: root)
        #expect(entries.map(\.name) == ["crash", "settings"])
    }
}
