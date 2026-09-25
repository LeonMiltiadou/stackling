import Foundation
import Testing
@testable import StacklingKit

@MainActor
@Suite struct JevTests {
    @Test func picksTheProviderFromTheKey() {
        #expect(Jev.Provider.forKey("sk-or-v1-abc") == .openrouter)
        #expect(Jev.Provider.forKey("ts_live_abc") == .typesafe)
        #expect(Jev.Provider.openrouter.endpoint.absoluteString == "https://openrouter.ai/api/v1/systemone")
    }

    @Test func buildsTheDocumentedRequest() throws {
        let body = try Jev.body(state: ["screenshot_text": "TypeError"], questions: [
            "folder": .choice("Which folder?", options: ["Bugs": "Errors", "none": "Nothing fits"]),
            "real": .yesNo("Is it real?"),
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "jev-latest")
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(questions["folder"]?["type"] as? String == "choice")
        #expect((questions["folder"]?["criteria"] as? [String: String])?["Bugs"] == "Errors")
        #expect(questions["real"]?["type"] as? String == "noul")
    }

    @Test func readsARealAnswer() throws {
        // Recorded from a live OpenRouter call on 25 September 2026.
        let recorded = """
        {"model":"typesafe/jev-1.13-20260917","answers":{
          "folder":{"type":"choice","choice":"Bugs","probabilities":{"Design":0,"Monitoring":0,"Bugs":1,"none":0},"confidence":1},
          "real":{"type":"noul","noul":0.99}},"usage":{"input_tokens":399,"output_tokens":64,"cost":1.6758e-05}}
        """
        let answers = try Jev.decode(Data(recorded.utf8))
        #expect(answers["folder"]?.choice == "Bugs")
        #expect(answers["folder"]?.confidence == 1)
        #expect(answers["real"]?.noul == 0.99)
    }

    @Test func autoFilingOnlyMovesWhenSure() {
        let folders = [URL(fileURLWithPath: "/L/Bugs"), URL(fileURLWithPath: "/L/Design")]
        func answer(_ choice: String, _ confidence: Double) -> Jev.Answer {
            Jev.Answer(type: "choice", noul: nil, choice: choice, probabilities: nil, confidence: confidence)
        }
        #expect(AutoFiler.decide(answer("Bugs", 0.95), folders: folders)?.lastPathComponent == "Bugs")
        #expect(AutoFiler.decide(answer("Bugs", 0.5), folders: folders) == nil, "not sure enough")
        #expect(AutoFiler.decide(answer("none", 0.99), folders: folders) == nil)
        #expect(AutoFiler.decide(answer("Gone", 0.99), folders: folders) == nil, "a folder that no longer exists")
        #expect(AutoFiler.decide(nil, folders: folders) == nil)
    }

    @Test func otherSecretsOnTheSameLineAreHiddenToo() {
        let key = "sk_" + "live_51HxQpLmNoPqRsTuVwXyZ0123", pass = "hunter2hunter2!"
        let line = "KEY=\(key) PASSWORD=\(pass)"
        let found = [SecretFinder.Found(kind: .apiKey, rect: .zero, text: key, line: line),
                     SecretFinder.Found(kind: .password, rect: .zero, text: pass, line: line)]
        let sent = SecretCheck.line(around: found[0], among: found)
        #expect(sent == "KEY=[candidate] PASSWORD=[another candidate]")
        #expect(!sent.contains(pass) && !sent.contains(key))
    }

    @Test func secretsAreMaskedBeforeLeaving() {
        let secret = "sk_" + "live_51HxQpLmNoPqRsTuVwXyZ0123" // made up; split so secret scanners skip it
        let masked = SecretCheck.mask(secret)
        #expect(!masked.contains("51HxQ"), "the body of the secret never goes out")
        #expect(masked.hasPrefix("sk_l…"))
        #expect(masked.contains("\(secret.count) characters"))
        #expect(SecretCheck.mask("hunter2") == "… (7 characters: letters, digits)", "short secrets show nothing at all")
    }

    /// A real call through the provider for the key. Costs a tiny fraction of a penny; only runs when asked:
    /// STACKLING_JEV_KEY=… swift test --filter JevTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STACKLING_JEV_KEY"] != nil))
    func answersForReal() async throws {
        let key = ProcessInfo.processInfo.environment["STACKLING_JEV_KEY"]!
        let folders = [URL(fileURLWithPath: "/L/Bugs"), URL(fileURLWithPath: "/L/Design"), URL(fileURLWithPath: "/L/Monitoring")]
        let answers = try await Jev.ask(
            state: ["screenshot_text": "Unhandled Runtime Error TypeError: cart.items is undefined src/checkout/Summary.tsx (42:18)"],
            questions: ["folder": AutoFiler.question(for: folders)], key: key
        )
        #expect(AutoFiler.decide(answers["folder"], folders: folders)?.lastPathComponent == "Bugs")
    }
}
