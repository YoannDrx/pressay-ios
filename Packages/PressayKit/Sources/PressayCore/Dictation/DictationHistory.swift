import CryptoKit
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

/// The app's local history, outside the App Group so neither the keyboard nor the widgets
/// can read past dictations.
///
/// Encrypted twice: the file is sealed with AES-GCM under a key that never leaves this
/// iPhone (the app keeps it in the Keychain, `ThisDeviceOnly`), so a backup or a copied
/// container holds only ciphertext; and iOS Data Protection encrypts the file at rest until
/// the first unlock after a restart.
public struct DictationHistory: Sendable {
    public static let capacity = 200

    public let fileURL: URL
    private let key: SymmetricKey

    public init(fileURL: URL, key: SymmetricKey) {
        self.fileURL = fileURL
        self.key = key
    }

    /// `Application Support/history.json` of the current process.
    public static func applicationSupport(key: SymmetricKey) -> DictationHistory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DictationHistory(fileURL: base.appendingPathComponent("history.json"), key: key)
    }

    /// Newest first. A file written before encryption (builds of lots I2 and I3) is read as is.
    public func entries() throws -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        if let legacy = Self.legacyEntries(data) {
            return legacy
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key)
        return try JSONDecoder.history.decode([HistoryEntry].self, from: plain)
    }

    /// Rewrites a history saved in clear by an earlier build, encrypted. Does nothing otherwise.
    public func encryptLegacyFile() throws {
        guard let data = try? Data(contentsOf: fileURL), let legacy = Self.legacyEntries(data) else { return }
        try write(legacy)
    }

    public var isEncrypted: Bool {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return true }
        return Self.legacyEntries(data) == nil
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

    private static func legacyEntries(_ data: Data) -> [HistoryEntry]? {
        // Sealed boxes start with a random nonce, never with a JSON array.
        guard data.first == UInt8(ascii: "[") else { return nil }
        return try? JSONDecoder.history.decode([HistoryEntry].self, from: data)
    }

    private func write(_ items: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plain = try JSONEncoder.history.encode(items)
        guard let data = try AES.GCM.seal(plain, using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
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
