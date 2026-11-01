import Foundation
import Security

/// Small secrets of the account layer: tokens, the signed rights, sync keys.
public protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

/// The app's Keychain. `ThisDeviceOnly`: left out of backups, never migrates to another iPhone.
/// Readable after the first unlock, because a dictation can start from the Lock Screen. Stays in
/// the app's default access group, which needs no entitlement: the keyboard cannot read it.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "fr.yodev.pressay.account") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func data(for key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw CloudFailure.keychainUnavailable
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CloudFailure.keychainUnavailable }
        let added = SecItemAdd(query(key).merging(update) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw CloudFailure.keychainUnavailable }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudFailure.keychainUnavailable
        }
    }
}

/// For tests.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(for key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func set(_ data: Data, for key: String) throws {
        lock.withLock { values[key] = data }
    }

    public func remove(_ key: String) throws {
        lock.withLock { values[key] = nil }
    }

    public var keys: [String] {
        lock.withLock { Array(values.keys) }
    }
}
