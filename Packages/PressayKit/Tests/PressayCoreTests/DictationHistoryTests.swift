import CryptoKit
import Foundation
import Testing
@testable import PressayCore

@Suite struct DictationHistoryTests {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationHistoryTests-\(UUID().uuidString)")
        .appendingPathComponent("history.json")
    let key = SymmetricKey(size: .bits256)
    var history: DictationHistory { DictationHistory(fileURL: fileURL, key: key) }

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

    @Test func storesNoTextInClear() throws {
        try history.add(entry("rendez-vous confidentiel"))
        let data = try Data(contentsOf: fileURL)
        #expect(data.range(of: Data("confidentiel".utf8)) == nil)
        #expect(history.isEncrypted)
        #expect(try history.entries().map(\.text) == ["rendez-vous confidentiel"])
    }

    @Test func anotherKeyCannotReadIt() throws {
        try history.add(entry("secret"))
        let stranger = DictationHistory(fileURL: fileURL, key: SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) { try stranger.entries() }
    }

    @Test func readsAndEncryptsAHistoryWrittenInClear() throws {
        let legacy = [entry("ancien")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(legacy).write(to: fileURL)
        #expect(!history.isEncrypted)
        #expect(try history.entries().map(\.text) == ["ancien"])

        try history.encryptLegacyFile()
        #expect(history.isEncrypted)
        #expect(try history.entries().map(\.id) == legacy.map(\.id))
    }

    @Test func searchIgnoresCaseAndAccents() {
        let entries = [entry("L'été à Paris"), entry("Réunion lundi"), entry("Liste de courses")]
        #expect(entries.matching("ete paris").map(\.text) == ["L'été à Paris"])
        #expect(entries.matching("REUNION").map(\.text) == ["Réunion lundi"])
        #expect(entries.matching("  ").count == 3)
        #expect(entries.matching("demain").isEmpty)
    }
}
