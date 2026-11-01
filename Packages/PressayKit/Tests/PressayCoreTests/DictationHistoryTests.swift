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
        for index in 0..<8 {
            try history.add(entry("\(index)", at: now.addingTimeInterval(Double(index))), capacity: 3)
        }
        let entries = try history.entries()
        #expect(entries.count == 3)
        #expect(entries.first?.text == "7")
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

    @Test func freeKeepsAWideHistoryAndProKeepsEverything() throws {
        for index in 0..<3 {
            try history.add(entry("\(index)", at: Date(timeIntervalSince1970: TimeInterval(index))), capacity: 2)
        }
        #expect(try history.entries().map(\.text) == ["2", "1"])
        try history.add(entry("3", at: Date(timeIntervalSince1970: 3)), capacity: nil)
        try history.add(entry("4", at: Date(timeIntervalSince1970: 4)), capacity: nil)
        #expect(try history.entries().count == 4)
    }

    @Test func freeSeesTheLastDaysAndNothingIsLost() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            entry("recent", at: now.addingTimeInterval(-6 * 86_400)),
            entry("old", at: now.addingTimeInterval(-8 * 86_400)),
        ]
        #expect(entries.visibleEntries(isPro: false, freeDays: 7, now: now).map(\.text) == ["recent"])
        #expect(entries.visibleEntries(isPro: true, freeDays: 7, now: now).count == 2)
    }

    @Test func aRewrittenEntryKeepsItsOriginalAndOlderFilesStillDecode() throws {
        let rewritten = HistoryEntry(
            text: "Bonjour", engine: .fast, audioSeconds: 1, transcriptionSeconds: 0.1, originalText: "bonjour euh", modeID: "email"
        )
        try history.add(rewritten)
        #expect(try history.entries().first?.originalText == "bonjour euh")
        let older = """
        {"id":"\(UUID().uuidString)","text":"t","engine":"fast","createdAt":"2026-10-01T10:00:00Z",\
        "audioSeconds":1,"transcriptionSeconds":1,"recovered":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(HistoryEntry.self, from: Data(older.utf8)).modeID == nil)
    }
}
