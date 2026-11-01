import CryptoKit
import Foundation

/// The rights an entitlement token proves.
public struct VerifiedEntitlement: Equatable, Sendable {
    public let tier: EntitlementTier
    public let source: EntitlementSource
    public let revision: Int
    public let issuedAt: Date
    public let expiresAt: Date
    public let onlineValidUntil: Date?
    public let offlineGraceUntil: Date?
}

/// Checks a signed entitlement token locally, so Pro works offline and nobody can grant it by
/// answering in the server's place. Same rules as `verify_entitlement_token` in the Mac app: the
/// pinned key, the issuer, the shared bundle as audience, this account and this device, and a
/// token that has not expired. The server bounds that expiry to 72 hours for Pro, 24 for Free.
public struct EntitlementVerifier: Sendable {
    /// A token issued in the future beyond this margin means a tampered clock.
    static let clockSkew: TimeInterval = 300

    private let keyID: String
    private let issuer: String
    private let publicKey: Curve25519.Signing.PublicKey

    public init(configuration: CloudConfiguration) throws {
        guard let raw = Data(base64URL: configuration.entitlementPublicKey), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { throw CloudFailure("cloud_entitlement_config_invalid") }
        keyID = configuration.entitlementKeyID
        issuer = configuration.entitlementIssuer
        publicKey = key
    }

    private struct Header: Decodable {
        let alg: String
        let kid: String
        let typ: String
    }

    private struct Claims: Decodable {
        let tier: EntitlementTier
        let source: EntitlementSource
        let revision: Int
        let device_id: String // swiftlint:disable:this identifier_name
        let online_valid_until: Double? // swiftlint:disable:this identifier_name
        let offline_grace_until: Double? // swiftlint:disable:this identifier_name
        let iss: String
        let aud: [String]
        let sub: String
        let iat: Double
        let exp: Double
    }

    public func verify(token: String, accountID: String, deviceID: String, now: Date) throws -> VerifiedEntitlement {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]),
              let claimsData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "EdDSA", header.kid == keyID, header.typ == "JWT",
              publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)),
              let claims = try? JSONDecoder().decode(Claims.self, from: claimsData)
        else { throw CloudFailure.entitlementInvalid }

        let seconds = now.timeIntervalSince1970
        guard claims.iss == issuer,
              claims.aud.contains(CloudConfiguration.entitlementAudience),
              claims.sub == accountID,
              claims.device_id == deviceID,
              claims.iat <= seconds + Self.clockSkew,
              claims.exp > seconds,
              claims.revision > 0
        else { throw CloudFailure.entitlementInvalid }

        return VerifiedEntitlement(
            tier: claims.tier,
            source: claims.source,
            revision: claims.revision,
            issuedAt: Date(timeIntervalSince1970: claims.iat),
            expiresAt: Date(timeIntervalSince1970: claims.exp),
            onlineValidUntil: claims.online_valid_until.map(Date.init(timeIntervalSince1970:)),
            offlineGraceUntil: claims.offline_grace_until.map(Date.init(timeIntervalSince1970:))
        )
    }
}
