import Foundation
import Testing
@testable import StacklingKit

/// One suite, run in order, because the log's location is shared.
@Suite(.serialized)
struct ActivityLogTests {
    private func lines(at url: URL) throws -> [[String: Any]] {
        ActivityLog.flush()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func recordsWhatHappenedAndHow() throws {
        let folder = try TempFolder()
        let url = folder.url.appendingPathComponent("activity.jsonl")
        ActivityLog.testURL = url
        defer { ActivityLog.testURL = nil }

        // Other tests run alongside and may log too; this one's lines carry a probe tag.
        let probe = UUID().uuidString
        ActivityLog.recordLaunch(version: probe)
        ActivityLog.via("key") { ActivityLog.record(.copy, ["kind": "still", "age": 4, "probe": probe]) }
        ActivityLog.record(.dismiss, ["probe": probe])

        let logged = try lines(at: url).filter { $0["probe"] as? String == probe || $0["version"] as? String == probe }
        #expect(logged.map { $0["e"] as? String } == ["app.launch", "shot.copy", "shot.dismiss"])
        #expect((logged[0]["catalogue"] as? [String])?.contains("library.search") == true, "the catalogue lets a summary find unused features")
        #expect(logged[1]["via"] as? String == "key")
        #expect(logged[1]["age"] as? Int == 4)
        #expect(logged[2]["via"] == nil, "the key only applies inside via")
        #expect(logged.allSatisfy { $0["t"] is String })
    }

    @Test func eventNamesAreUnique() {
        let names = ActivityLog.Event.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }
}
