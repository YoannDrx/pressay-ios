import Foundation
import Testing
@testable import PressayShared

@Suite struct PressayLogTests {
    @Test func appendsOneJSONObjectPerEvent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = PressayLog(fileURL: url, process: "tests")

        log.event("dictation.started", ["engine": .tag("fast")])
        log.event("dictation.finished", ["words": 12, "seconds": 0.14, "inserted": true])

        let lines = log.readAll().split(separator: "\n")
        #expect(lines.count == 2)
        let last = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        #expect(last["event"] as? String == "dictation.finished")
        #expect(last["words"] as? Int == 12)
        #expect(last["inserted"] as? Bool == true)
        #expect(last["process"] as? String == "tests")
        #expect(last["at"] is String)
    }

    @Test func clearRemovesTheJournal() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        let log = PressayLog(fileURL: url, process: "tests")
        log.event("app.launched")
        log.clear()
        #expect(log.readAll().isEmpty)
    }
}
