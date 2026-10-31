import Foundation
import Testing
@testable import PressayCore

@Suite struct DictationHistoryTests {
    let history = DictationHistory(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationHistoryTests-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
    )

    func entry(_ text: String, at date: Date = Date(), recovered: Bool = false) -> HistoryEntry {
        HistoryEntry(text: text, engine: .fast, createdAt: date, audioSeconds: 2, transcriptionSeconds: 0.1, recovered: recovered)
    }

    @Test func startsEmpty() throws {
        #expect(try history.entries().isEmpty)
    }

    @Test func keepsTheNewestFirst() throws {
        let now = Date()
        try history.add(entry("deux", at: now))
        try history.add(entry("un", at: now.addingTimeInterval(-60)))
        try history.add(entry("trois", at: now.addingTimeInterval(60)))
        #expect(try history.entries().map(\.text) == ["trois", "deux", "un"])
    }

    @Test func keepsAtMostCapacityEntries() throws {
        let now = Date()
        for index in 0..<(DictationHistory.capacity + 5) {
            try history.add(entry("\(index)", at: now.addingTimeInterval(Double(index))))
        }
        let entries = try history.entries()
        #expect(entries.count == DictationHistory.capacity)
        #expect(entries.first?.text == "\(DictationHistory.capacity + 4)")
    }

    @Test func keepsTheRecoveredFlagAndConvertsToAResult() throws {
        let saved = entry("récupéré", recovered: true)
        try history.add(saved)
        let read = try #require(try history.entries().first)
        #expect(read.recovered)
        #expect(read.result.id == saved.id)
        #expect(read.result.engine == "fast")
    }

    @Test func removesOneEntry() throws {
        let kept = entry("garder")
        let removed = entry("supprimer")
        try history.add(kept)
        try history.add(removed)
        try history.remove(id: removed.id)
        #expect(try history.entries().map(\.id) == [kept.id])
    }

    @Test func clears() throws {
        try history.add(entry("un"))
        try history.removeAll()
        #expect(try history.entries().isEmpty)
    }
}
