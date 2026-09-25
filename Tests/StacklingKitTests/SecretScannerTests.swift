import AppKit
import Testing
@testable import StacklingKit

@Suite struct SecretScannerTests {
    private func found(_ text: String) -> [(SecretScanner.Kind, String)] {
        SecretScanner.matches(in: text).map { ($0.kind, String(text[$0.range])) }
    }

    @Test func findsCommonKeysAndTokens() {
        let text = "key sk-ant-api03-EXAMPLEexampleEXAMPLE and ghp_EXAMPLEexampleEXAMPLEexampleEXAMPLE1 AKIAEXAMPLEEXAMPLE12"
        let kinds = found(text).map(\.0)
        #expect(kinds == [.apiKey, .token, .apiKey])
    }

    @Test func hidesOnlyThePasswordValue() {
        let matches = found("DB_PASSWORD=hunter2secret")
        #expect(matches.count == 1)
        #expect(matches.first?.1 == "hunter2secret")
    }

    @Test func hidesBearerTokensButNotTheWordBearer() {
        #expect(found("Authorization: Bearer abcdefghijklmnop1234").first?.1 == "abcdefghijklmnop1234")
    }

    @Test func findsPasswordsInConnectionStrings() {
        #expect(found("DATABASE_URL=postgres://app:localdev@db:5432/app").first?.1 == "localdev")
    }

    @Test func findsEmailsAndJWTs() {
        let kinds = found("mail someone@example.com token eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4").map(\.0)
        #expect(kinds == [.email, .jwt])
    }

    @Test func cardNumbersMustPassTheChecksum() {
        #expect(found("card 4242 4242 4242 4242").map(\.0) == [.cardNumber])
        #expect(found("order 1234 5678 9012 3456").isEmpty)
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(found("Build succeeded in 3.2s, 40 tests passed, commit 8a3a06e").isEmpty)
    }

    /// Draws text into an image and checks Vision + the scanner put a box around the secret, not the label.
    @Test func findsASecretInAnImage() async throws {
        let size = NSSize(width: 1200, height: 160)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("export OPENAI_API_KEY=sk-proj-EXAMPLEexampleEXAMPLEexample" as NSString).draw(
                at: NSPoint(x: 20, y: 60),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.black]
            )
            return true
        }
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let found = await SecretFinder.find(in: cg)
        #expect(found.count == 1)
        let box = try #require(found.first?.rect)
        // Vision boxes whole words, so the box may take in "OPENAI_API_KEY=" too, but never "export",
        // and it must reach the end of the key.
        #expect(box.minX > CGFloat(cg.width) * 0.08)
        #expect(box.maxX > CGFloat(cg.width) * 0.7)
    }
}
