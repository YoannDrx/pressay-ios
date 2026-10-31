import CryptoKit
import Foundation
import Security

/// The key that seals the history, kept in the app's Keychain. `ThisDeviceOnly`: it is left
/// out of backups and never migrates to another iPhone, so neither can a backup's history.
/// Readable after the first unlock, like the history file, so a dictation started from the
/// Lock Screen is still saved.
enum HistoryKey {
    enum Failure: Error {
        /// The Keychain is locked (before the first unlock after a restart): retry later.
        /// Never answered with a new key, which would make the saved history unreadable.
        case unavailable(OSStatus)
    }

    private static let service = "fr.yodev.pressay.history"
    private static let account = "history-key-v1"

    static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try load() {
            return raced
        }
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
        return key
    }

    private static func load() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { throw Failure.unavailable(status) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unavailable(status)
        }
    }
}
