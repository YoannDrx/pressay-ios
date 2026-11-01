import CryptoKit
import Foundation

public enum SyncObjectType: String, Codable, Sendable {
    case mode, profile, dictionary, preference
}

public enum SyncStatus: Equatable, Sendable {
    case notConfigured
    /// Waiting for an approved device, or for the recovery code.
    case pendingApproval
    case ready
}

public struct SyncDevice: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let status: SyncStatus
    public let isCurrent: Bool
}

public struct SyncSnapshot: Equatable, Sendable {
    public let status: SyncStatus
    public let devices: [SyncDevice]
}

public struct SyncRunReport: Equatable, Sendable {
    public let uploaded: Int
    public let downloaded: Int
    public let conflictsPreserved: Int
    public let nextCursor: Int
}

struct SyncChangeInput: Codable, Equatable {
    let objectType: SyncObjectType
    let objectId: String
    let revision: Int
    let envelope: String
    let envelopeVersion: Int
    let tombstone: Bool
}

struct SyncChangeOutput: Decodable {
    let objectType: SyncObjectType
    let objectId: String
    let revision: Int
    let envelope: String
    let envelopeVersion: Int
    let tombstone: Bool
    let sequenceId: Int
    let sourceDeviceId: String
    let conflict: Bool
}

struct SyncChangesResponse: Decodable {
    let changes: [SyncChangeOutput]
    let nextCursor: Int
    let hasMore: Bool
}

struct AppendSyncChangesRequest: Encodable {
    let deviceId: String
    let changes: [SyncChangeInput]
}

struct AppendSyncChangesResponse: Decodable {
    let accepted: Int
    let conflicts: Int
    let cursor: Int
}

struct SyncEnrollRequest: Encodable {
    let deviceId: String
    let publicKey: String
    let encryptedAccountKey: String?
}

struct SyncEnrollResponse: Decodable { let status: String }
struct SyncEnvelopeResponse: Decodable { let encryptedAccountKey: String }

struct SyncDeviceListResponse: Decodable {
    struct Device: Decodable {
        let id: String
        let displayName: String
        let publicKey: String
        let status: String
    }
    let devices: [Device]
}

struct SyncApproveRequest: Encodable {
    let approverDeviceId: String
    let encryptedAccountKey: String
}

struct SyncRecoveryRequest: Encodable {
    let deviceId: String
    let codeHash: String
    let encryptedAccountKey: String
}

struct SyncBeginRecoveryRequest: Encodable {
    let deviceId: String
    let publicKey: String
    let codeHash: String
}

/// The plaintext of an envelope: what `EncryptedPayload` holds on the Mac.
struct EncryptedPayload: Codable {
    let schemaVersion: Int
    let objectType: SyncObjectType
    let originalId: String
    let value: JSONValue
}

struct SyncedPreferences: Codable {
    let activeModeId: String
}

/// The identifiers and bindings the Mac computes, so both sides name an object the same way.
enum SyncFormat {
    static let schemaVersion = 1
    static let envelopeVersion = 1
    static let maximumEnvelopeBytes = 1_048_576
    static let preferenceID = "productivity"

    /// A UUID from `SHA-256("pressay-sync-object-v1:<type>:<id>")`: the original id stays private.
    static func objectUUID(_ type: SyncObjectType, _ originalID: String) -> String {
        let digest = SHA256.hash(data: Data("pressay-sync-object-v1:\(type.rawValue):\(originalID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

    static func aad(_ type: SyncObjectType, objectID: String, revision: Int, envelopeVersion: Int) -> Data {
        Data("pressay-sync-change:\(type.rawValue):\(objectID):\(revision):\(envelopeVersion)".utf8)
    }

    static func stateKey(_ type: SyncObjectType, _ originalID: String) -> String {
        "\(type.rawValue):\(originalID)"
    }

    static func hash(_ value: JSONValue) throws -> String {
        Data(SHA256.hash(data: try value.canonicalData())).base64URL
    }

    static func conflictID(_ originalID: String, sourceDeviceID: String, revision: Int) -> String {
        let suffix = "-sync-\(sourceDeviceID.prefix(8))-\(revision)"
        return String(originalID.prefix(max(0, 64 - suffix.count))) + suffix
    }
}

/// Revisions and the cursor, per account. Holds no content, only hashes.
struct SyncLocalState: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var revision = 0
        var hash = ""
        var tombstone = false
    }

    static let currentSchema = 1

    var schemaVersion = currentSchema
    let accountID: String
    var cursor = 0
    var entries: [String: Entry] = [:]
}

public protocol SyncStateStoring: Sendable {
    func read(accountID: String) throws -> Data?
    func write(_ data: Data, accountID: String) throws
    func remove(accountID: String) throws
}

public struct FileSyncStateStore: SyncStateStoring {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var applicationSupport: FileSyncStateStore {
        FileSyncStateStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    private func url(_ accountID: String) throws -> URL {
        guard let uuid = UUID(uuidString: accountID) else { throw CloudFailure("cloud_account_invalid") }
        return directory.appendingPathComponent("cloud-sync-\(uuid.uuidString.lowercased()).json")
    }

    public func read(accountID: String) throws -> Data? {
        try? Data(contentsOf: url(accountID))
    }

    public func write(_ data: Data, accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(accountID), options: .atomic)
    }

    public func remove(accountID: String) throws {
        try? FileManager.default.removeItem(at: url(accountID))
    }
}
