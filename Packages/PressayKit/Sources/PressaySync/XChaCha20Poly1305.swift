import CryptoKit
import Foundation

/// XChaCha20-Poly1305 on top of CryptoKit's ChaCha20-Poly1305, which only takes 96-bit nonces:
/// HChaCha20 derives a subkey from the key and the first 16 nonce bytes, then the IETF AEAD runs
/// with four zero bytes and the last 8 nonce bytes (draft-irtf-cfrg-xchacha-03). The Mac's sync
/// envelopes use this construction through the RustCrypto `chacha20poly1305` crate.
enum XChaCha20Poly1305 {
    static let nonceLength = 24
    static let tagLength = 16

    static func seal(_ plaintext: Data, key: Data, nonce: Data, authenticating aad: Data) throws -> Data {
        let (subkey, inner) = try derive(key: key, nonce: nonce)
        let box = try ChaChaPoly.seal(plaintext, using: subkey, nonce: inner, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ combined: Data, key: Data, nonce: Data, authenticating aad: Data) throws -> Data {
        guard combined.count >= tagLength else { throw CryptoKitError.authenticationFailure }
        let (subkey, inner) = try derive(key: key, nonce: nonce)
        let split = combined.startIndex + combined.count - tagLength
        let box = try ChaChaPoly.SealedBox(nonce: inner, ciphertext: combined[combined.startIndex..<split], tag: combined[split...])
        return try ChaChaPoly.open(box, using: subkey, authenticating: aad)
    }

    private static func derive(key: Data, nonce: Data) throws -> (SymmetricKey, ChaChaPoly.Nonce) {
        guard key.count == 32, nonce.count == nonceLength else { throw CryptoKitError.incorrectParameterSize }
        let nonce = Data(nonce)
        let subkey = hChaCha20(key: Data(key), nonce: nonce.prefix(16))
        let inner = try ChaChaPoly.Nonce(data: Data(count: 4) + nonce.suffix(8))
        return (SymmetricKey(data: subkey), inner)
    }

    static func hChaCha20(key: Data, nonce: Data) -> Data {
        var state: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
        state += words(key)
        state += words(nonce)
        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }
        var output = Data(capacity: 32)
        for word in state[0..<4] + state[12..<16] {
            withUnsafeBytes(of: word.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func words(_ data: Data) -> [UInt32] {
        let bytes = [UInt8](data)
        var words: [UInt32] = []
        for index in stride(from: 0, to: bytes.count, by: 4) {
            var word = UInt32(bytes[index])
            word |= UInt32(bytes[index + 1]) << 8
            word |= UInt32(bytes[index + 2]) << 16
            word |= UInt32(bytes[index + 3]) << 24
            words.append(word)
        }
        return words
    }

    // swiftlint:disable:next identifier_name
    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = s[d] << 16 | s[d] >> 16
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = s[b] << 12 | s[b] >> 20
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = s[d] << 8 | s[d] >> 24
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = s[b] << 7 | s[b] >> 25
    }
}
