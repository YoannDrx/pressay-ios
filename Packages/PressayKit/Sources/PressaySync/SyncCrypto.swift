import CryptoKit
import Foundation
import PressayAccount

/// A new recovery code (shown once), its hash and the account key sealed under it.
public struct RecoveryEnvelope: Sendable {
    public let code: String
    public let hash: Data
    public let envelope: Data
}

/// The envelopes of `sync_crypto.rs`, byte for byte: an iPhone and a Mac open each other's.
/// The test suite pins this against vectors the Rust code generated.
public enum SyncCrypto {
    static let sealedKeyMagic = Data("PRSYSK01".utf8)
    static let syncDataMagic = Data("PRSYSY01".utf8)
    static let recoveryKeyMagic = Data("PRSYRC01".utf8)
    static let recoveryCodePrefix = "PRS1"
    static let keyLength = 32

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: Device keys

    public static func generateDeviceKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    public static func publicKey(forDeviceKey privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    public static func generateAccountKey() -> Data {
        randomBytes(keyLength)
    }

    // MARK: Account key sealed to a device

    private static func wrappingKey(sharedSecret: SharedSecret, ephemeralPublic: Data, recipientPublic: Data) -> Data {
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("Pressay sync key wrapping v1".utf8),
            sharedInfo: ephemeralPublic + recipientPublic,
            outputByteCount: keyLength
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public static func sealAccountKey(_ accountKey: Data, toPublicKey recipientPublic: Data) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublic)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = wrappingKey(sharedSecret: shared, ephemeralPublic: ephemeralPublic, recipientPublic: recipientPublic)
        let nonce = randomBytes(XChaCha20Poly1305.nonceLength)
        let sealed = try XChaCha20Poly1305.seal(accountKey, key: key, nonce: nonce, authenticating: sealedKeyMagic)
        return sealedKeyMagic + ephemeralPublic + nonce + sealed
    }

    public static func openAccountKey(_ envelope: Data, deviceKey: Data) throws -> Data {
        let envelope = Data(envelope)
        let magic = sealedKeyMagic.count
        let publicEnd = magic + 32
        let nonceEnd = publicEnd + XChaCha20Poly1305.nonceLength
        guard envelope.count == nonceEnd + keyLength + XChaCha20Poly1305.tagLength,
              envelope.prefix(magic) == sealedKeyMagic
        else { throw CloudFailure("cloud_sync_envelope_invalid") }
        let ephemeralPublic = Data(envelope[magic..<publicEnd])
        let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: deviceKey)
        let shared = try device.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic)
        )
        let key = wrappingKey(sharedSecret: shared, ephemeralPublic: ephemeralPublic, recipientPublic: device.publicKey.rawRepresentation)
        return try XChaCha20Poly1305.open(
            Data(envelope[nonceEnd...]), key: key, nonce: Data(envelope[publicEnd..<nonceEnd]), authenticating: sealedKeyMagic
        )
    }

    // MARK: Sync objects

    public static func encryptChange(_ plaintext: Data, accountKey: Data, aad: Data) throws -> Data {
        let nonce = randomBytes(XChaCha20Poly1305.nonceLength)
        let sealed = try XChaCha20Poly1305.seal(plaintext, key: accountKey, nonce: nonce, authenticating: aad)
        return syncDataMagic + nonce + sealed
    }

    public static func decryptChange(_ envelope: Data, accountKey: Data, aad: Data) throws -> Data {
        let envelope = Data(envelope)
        let nonceEnd = syncDataMagic.count + XChaCha20Poly1305.nonceLength
        guard envelope.count >= nonceEnd + XChaCha20Poly1305.tagLength,
              envelope.prefix(syncDataMagic.count) == syncDataMagic
        else {
            throw CloudFailure("cloud_sync_envelope_invalid")
        }
        return try XChaCha20Poly1305.open(
            Data(envelope[nonceEnd...]),
            key: accountKey,
            nonce: Data(envelope[syncDataMagic.count..<nonceEnd]),
            authenticating: aad
        )
    }

    // MARK: Recovery code

    private static func recoverySecret(code: String) throws -> Data {
        let compact = code.filter { !$0.isWhitespace }
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == recoveryCodePrefix,
              let secret = Data(base64URL: String(parts[1])), secret.count == keyLength
        else { throw CloudFailure("cloud_sync_recovery_code_invalid") }
        return secret
    }

    private static func recoveryWrappingKey(secret: Data) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("Pressay sync recovery v1".utf8),
            info: Data("account key envelope".utf8),
            outputByteCount: keyLength
        ).withUnsafeBytes { Data($0) }
    }

    static func formatRecoveryCode(secret: Data) -> String {
        let encoded = Array(secret.base64URL)
        let groups = stride(from: 0, to: encoded.count, by: 5).map { index in
            String(encoded[index..<min(index + 5, encoded.count)])
        }
        return "\(recoveryCodePrefix).\(groups.joined(separator: " "))"
    }

    public static func recoveryCodeHash(_ code: String) throws -> Data {
        Data(SHA256.hash(data: try recoverySecret(code: code)))
    }

    public static func createRecoveryEnvelope(accountKey: Data) throws -> RecoveryEnvelope {
        let secret = randomBytes(keyLength)
        let nonce = randomBytes(XChaCha20Poly1305.nonceLength)
        let sealed = try XChaCha20Poly1305.seal(
            accountKey, key: recoveryWrappingKey(secret: secret), nonce: nonce, authenticating: recoveryKeyMagic
        )
        return RecoveryEnvelope(
            code: formatRecoveryCode(secret: secret),
            hash: Data(SHA256.hash(data: secret)),
            envelope: recoveryKeyMagic + nonce + sealed
        )
    }

    public static func openRecoveryEnvelope(code: String, envelope: Data) throws -> Data {
        let envelope = Data(envelope)
        let nonceEnd = recoveryKeyMagic.count + XChaCha20Poly1305.nonceLength
        guard envelope.count == nonceEnd + keyLength + XChaCha20Poly1305.tagLength,
              envelope.prefix(recoveryKeyMagic.count) == recoveryKeyMagic
        else { throw CloudFailure("cloud_sync_envelope_invalid") }
        return try XChaCha20Poly1305.open(
            Data(envelope[nonceEnd...]),
            key: recoveryWrappingKey(secret: recoverySecret(code: code)),
            nonce: Data(envelope[recoveryKeyMagic.count..<nonceEnd]),
            authenticating: recoveryKeyMagic
        )
    }
}
