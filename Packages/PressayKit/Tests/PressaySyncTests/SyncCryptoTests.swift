// swiftlint:disable line_length
import Foundation
import Testing
import PressayAccount
@testable import PressaySync

private func hex(_ value: String) -> Data {
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        data.append(UInt8(value[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@Suite struct XChaChaVectorsTests {
    /// draft-irtf-cfrg-xchacha-03, section 2.2.1.
    @Test func hChaCha20() {
        let output = XChaCha20Poly1305.hChaCha20(
            key: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            nonce: hex("000000090000004a0000000031415927")
        )
        #expect(output == hex("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"))
    }

    /// draft-irtf-cfrg-xchacha-03, appendix A.3.1.
    @Test func aead() throws {
        let plaintext = Data(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8
        )
        let aad = hex("50515253c0c1c2c3c4c5c6c7")
        let key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = hex("404142434445464748494a4b4c4d4e4f5051525354555657")
        let expected = hex(
            "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39"
                + "ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3ff"
                + "f921f9664c97637da9768812f615c68b13b52e"
                + "c0875924c1c7987947deafd8780acf49"
        )
        #expect(try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, authenticating: aad) == expected)
        #expect(try XChaCha20Poly1305.open(expected, key: key, nonce: nonce, authenticating: aad) == plaintext)
        #expect(throws: (any Error).self) {
            try XChaCha20Poly1305.open(expected, key: key, nonce: nonce, authenticating: Data())
        }
    }
}

/// Envelopes produced by the Mac's `sync_crypto.rs`, with synthetic keys. If one of these breaks,
/// an iPhone and a Mac no longer understand each other.
enum MacVectors {
    static let accountKey = Data(repeating: 0x11, count: 32)
    static let deviceKey = Data(repeating: 0x22, count: 32)
    static let devicePublic = "D6poTtKIZ7l/Smot7l34zpdOdrcBjj8iocTPJnhXDyA="
    static let sealed = "UFJTWVNLMDFxh8bVFgMBmZ3AYgH/O8Krq5mln2uC2hi3Z459QBBVZNJonVvGpheDRcfKcsyfpuN1GW3rNrwAUaTttBS/VBg7RvF7OC0KkWT6AACFSYjt89vm9Kb2sUMEao7dNGVylonvar0aEoxk2Q=="
    static let changeAAD = "pressay-sync-change:dictionary:7d1f2c3a-0000-5000-8000-000000000000:3:1"
    static let change = "UFJTWVNZMDFXqjEC+d4GTG4L8o3EObPTfVrCP7iYsbKp/OxuVtLFSdqAjxcNEAMIqHTV/tK4+MSNxqYgvRuy7BQh+FY1dea6LYhqJXsF+UmiDbgZhBZdM6j7w5R9zt7/RAsUngPk8I5e84rjDPWa/2JkwBsMqMKFuJgMncebtksD1lmDP+nO+etajY38gx7iybiZTY/DJ2zg139Cqr9iHcrSujqqgk8bNNGWS6BUJvC+wIZ7uj3JmEtP45EDkdLZ3IoJXxqGhsHVmeNHkQOTl05C+Ei/38WHCtUMDzJvk/yUFv0IG75v3yVE6G3HqPBdAM3gXseG+AR0hjjc7us="
    static let recoveryCode = "PRS1.-6txz nslvb XcZOt _U3jR IpAWn XA6W5 kQet7 _beo1 YdE"
    static let recoveryHash = "JmJny62NoEV2n4Y36QMPp+9rD3AeeiqYDHKf2j+7xxI="
    static let recoveryEnvelope = "UFJTWVJDMDG22qq2t8NmOsd6fTyrukWNFlGSxe/vV2v7hDqv1FAiAwobmJ9Y/hkrKj3Pl/4yKbDi/F+TbM4JyabEy0HVDzNbcTU2EXQgAfw="
}

@Suite struct SyncCryptoTests {
    @Test func opensWhatTheMacSealed() throws {
        #expect(try SyncCrypto.publicKey(forDeviceKey: MacVectors.deviceKey).base64EncodedString() == MacVectors.devicePublic)
        let opened = try SyncCrypto.openAccountKey(Data(base64Encoded: MacVectors.sealed)!, deviceKey: MacVectors.deviceKey)
        #expect(opened == MacVectors.accountKey)
    }

    @Test func readsAChangeTheMacEncrypted() throws {
        let plain = try SyncCrypto.decryptChange(
            Data(base64Encoded: MacVectors.change)!, accountKey: MacVectors.accountKey, aad: Data(MacVectors.changeAAD.utf8)
        )
        let payload = try JSONDecoder().decode(EncryptedPayload.self, from: plain)
        #expect(payload.objectType == .dictionary)
        let entry = try payload.value.decoded(as: DictionaryEntry.self)
        #expect(entry.term == "Pressay")
        #expect(entry.variants == ["presset"])
        #expect(entry.isValid)
        #expect(throws: (any Error).self) {
            try SyncCrypto.decryptChange(Data(base64Encoded: MacVectors.change)!, accountKey: MacVectors.accountKey, aad: Data("other".utf8))
        }
    }

    @Test func readsARecoveryCodeTheMacMade() throws {
        #expect(try SyncCrypto.recoveryCodeHash(MacVectors.recoveryCode).base64EncodedString() == MacVectors.recoveryHash)
        let opened = try SyncCrypto.openRecoveryEnvelope(code: MacVectors.recoveryCode, envelope: Data(base64Encoded: MacVectors.recoveryEnvelope)!)
        #expect(opened == MacVectors.accountKey)
        #expect(throws: CloudFailure("cloud_sync_recovery_code_invalid")) { try SyncCrypto.recoveryCodeHash("PRS2.abc") }
    }

    @Test func roundTrips() throws {
        let device = SyncCrypto.generateDeviceKey()
        let key = SyncCrypto.generateAccountKey()
        let sealed = try SyncCrypto.sealAccountKey(key, toPublicKey: SyncCrypto.publicKey(forDeviceKey: device))
        #expect(sealed.prefix(8) == Data("PRSYSK01".utf8))
        #expect(try SyncCrypto.openAccountKey(sealed, deviceKey: device) == key)

        let recovery = try SyncCrypto.createRecoveryEnvelope(accountKey: key)
        let (code, hash, envelope) = (recovery.code, recovery.hash, recovery.envelope)
        #expect(code.hasPrefix("PRS1."))
        #expect(code.contains(" "))
        #expect(try SyncCrypto.recoveryCodeHash(code) == hash)
        #expect(try SyncCrypto.openRecoveryEnvelope(code: code, envelope: envelope) == key)
    }

    @Test func objectIDsMatchTheMacFormat() {
        let id = SyncFormat.objectUUID(.mode, "my-private-mode")
        #expect(id == SyncFormat.objectUUID(.mode, "my-private-mode"))
        #expect(id != SyncFormat.objectUUID(.profile, "my-private-mode"))
        #expect(!id.contains("private"))
        #expect(id[id.index(id.startIndex, offsetBy: 14)] == "5")
        #expect(UUID(uuidString: id) != nil)
        #expect(SyncFormat.preferenceID == "productivity")
        #expect(String(data: SyncFormat.aad(.mode, objectID: "id", revision: 2, envelopeVersion: 1), encoding: .utf8) == "pressay-sync-change:mode:id:2:1")
    }

    @Test func conflictIDsAreBoundedAndTraceable() {
        let id = SyncFormat.conflictID(String(repeating: "a", count: 80), sourceDeviceID: "12345678-0000-0000-0000-000000000000", revision: 42)
        #expect(id.count <= 64)
        #expect(id.hasSuffix("-sync-12345678-42"))
    }
}
// swiftlint:enable line_length
