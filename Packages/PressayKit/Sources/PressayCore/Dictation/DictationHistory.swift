import Foundation
import PressayShared

/// One dictation kept in the app's history.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let engine: EngineID
    public let createdAt: Date
    public let audioSeconds: Double
    public let transcriptionSeconds: Double
    /// Transcribed at a later launch from a capture the system interrupted.
    public let recovered: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        engine: EngineID,
        createdAt: Date = Date(),
        audioSeconds: Double,
        transcriptionSeconds: Double,
        recovered: Bool = false
    ) {
        self.id = id
        self.text = text
        self.engine = engine
        self.createdAt = createdAt
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.recovered = recovered
    }

    public var result: DictationResult {
        DictationResult(
            id: id,
            text: text,
            engine: engine.rawValue,
            createdAt: createdAt,
            audioSeconds: audioSeconds,
            transcriptionSeconds: transcriptionSeconds
        )
    }
}

/// The app's local history: a JSON file outside the App Group, so neither the keyboard nor
/// the widgets can read past dictations. Minimal until lot I4 encrypts it and adds search.
public struct DictationHistory: Sendable {
    public static let capacity = 200

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `Application Support/history.json` of the current process.
    public static var applicationSupport: DictationHistory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DictationHistory(fileURL: base.appendingPathComponent("history.json"))
    }

    /// Newest first.
    public func entries() throws -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return try JSONDecoder.history.decode([HistoryEntry].self, from: data)
    }

    public func add(_ entry: HistoryEntry) throws {
        var items = try entries()
        items.insert(entry, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
        try write(items)
    }

    public func remove(id: UUID) throws {
        try write(entries().filter { $0.id != id })
    }

    public func removeAll() throws {
        try write([])
    }

    private func write(_ items: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder.history.encode(items)
        #if os(iOS)
        // Written after a dictation started from the Lock Screen.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
