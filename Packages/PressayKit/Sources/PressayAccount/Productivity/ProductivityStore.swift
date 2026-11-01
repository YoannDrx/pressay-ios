import CryptoKit
import Foundation

/// The dictionary, the modes and the preference, in the Mac's sync shapes.
public struct ProductivityDocument: Codable, Equatable, Sendable {
    public var dictionary: [DictionaryEntry] = []
    /// Custom modes from the Mac, kept whole.
    public var customModes: [JSONValue] = []
    /// Application profiles have no use on iPhone but must survive a sync run: dropping them here
    /// would delete them on the Mac.
    public var profiles: [JSONValue] = []
    public var activeModeID = PressayMode.faithfulID

    public init() {}

    public var modes: [PressayMode] {
        PressayMode.builtin + customModes.compactMap(PressayMode.init(custom:))
    }

    public var activeMode: PressayMode {
        modes.first { $0.id == activeModeID } ?? PressayMode.builtin[0]
    }

    /// The spellings worth keeping when a model rewrites a dictation.
    public var dictionaryTerms: [String] {
        var seen = Set<String>()
        return dictionary.filter(\.enabled).compactMap { entry in
            let term = (entry.replacement?.isEmpty == false ? entry.replacement : nil) ?? entry.term
            return seen.insert(term.lowercased()).inserted ? term : nil
        }
    }
}

/// Keeps the document sealed in the app's own container, out of the App Group: the keyboard has no
/// access to it. Changes go through `modify`, which an actor makes atomic, so a sync run and an edit
/// in the interface cannot overwrite each other.
public actor ProductivityStore {
    private static let keyName = "productivity-key-v1"

    private let fileURL: URL
    private let secrets: any SecretStore
    private var cached: ProductivityDocument?

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    public static func applicationSupport(secrets: any SecretStore) -> ProductivityStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProductivityStore(fileURL: base.appendingPathComponent("productivity.sealed"), secrets: secrets)
    }

    /// Empty when the Keychain is still locked (before the first unlock after a restart), and read
    /// again next time: a dictation then runs without the dictionary rather than failing.
    public func document() -> ProductivityDocument {
        if let cached { return cached }
        guard let key = try? key() else { return ProductivityDocument() }
        guard let data = try? Data(contentsOf: fileURL) else {
            cached = ProductivityDocument()
            return ProductivityDocument()
        }
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key),
              let document = try? JSONDecoder().decode(ProductivityDocument.self, from: plain)
        else { return ProductivityDocument() }
        cached = document
        return document
    }

    @discardableResult
    public func modify<Result: Sendable>(_ body: @Sendable (inout ProductivityDocument) throws -> Result) throws -> Result {
        var document = document()
        let result = try body(&document)
        if document != cached {
            try write(document)
            cached = document
        }
        return result
    }

    private func write(_ document: ProductivityDocument) throws {
        let plain = try JSONEncoder().encode(document)
        guard let data = try AES.GCM.seal(plain, using: key()).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private func key() throws -> SymmetricKey {
        if let data = try secrets.data(for: Self.keyName), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.set(key.withUnsafeBytes { Data($0) }, for: Self.keyName)
        return key
    }
}
