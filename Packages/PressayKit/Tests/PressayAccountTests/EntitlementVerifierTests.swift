import CryptoKit
import Foundation
import Testing
@testable import PressayAccount

@Suite struct EntitlementVerifierTests {
    let signer = TestSigner()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var verifier: EntitlementVerifier { get throws { try EntitlementVerifier(configuration: signer.configuration) } }

    func check(_ token: String) throws -> VerifiedEntitlement {
        try verifier.verify(token: token, accountID: TestIDs.account, deviceID: TestIDs.device, now: now)
    }

    func token(
        accountID: String = TestIDs.account,
        deviceID: String = TestIDs.device,
        audience: [String] = ["fr.yodev.pressay"],
        issuer: String = "https://api.press-say.app",
        issuedAt: Date? = nil,
        expiresAt: Date? = nil,
        keyID: String? = nil,
        alg: String = "EdDSA"
    ) throws -> String {
        try signer.token(
            accountID: accountID,
            deviceID: deviceID,
            audience: audience,
            issuer: issuer,
            issuedAt: issuedAt ?? now,
            expiresAt: expiresAt ?? now.addingTimeInterval(3600),
            keyID: keyID,
            alg: alg
        )
    }

    @Test func acceptsAValidToken() throws {
        let result = try check(token())
        #expect(result.tier == .pro)
        #expect(result.source == .appStore)
        #expect(result.revision == 3)
    }

    @Test(arguments: [
        "account", "device", "audience", "issuer", "expired", "future", "kid", "alg",
    ])
    func refuses(_ case: String) throws {
        let bad = switch `case` {
        case "account": try token(accountID: "someone-else")
        case "device": try token(deviceID: "another-device")
        case "audience": try token(audience: ["app.pressay.desktop"])
        case "issuer": try token(issuer: "https://evil.example")
        case "expired": try token(expiresAt: now)
        case "future": try token(issuedAt: now.addingTimeInterval(301))
        case "kid": try token(keyID: "other-key")
        default: try token(alg: "none")
        }
        #expect(throws: CloudFailure.entitlementInvalid) { try check(bad) }
    }

    @Test func refusesATamperedPayloadAndAnotherKey() throws {
        let valid = try token()
        var parts = valid.split(separator: ".").map(String.init)
        var claims = try #require(try JSONSerialization.jsonObject(with: Data(base64URL: parts[1])!) as? [String: Any])
        claims["tier"] = "pro"
        claims["revision"] = 99
        parts[1] = try JSONSerialization.data(withJSONObject: claims).base64URL
        #expect(throws: CloudFailure.entitlementInvalid) { try check(parts.joined(separator: ".")) }

        let other = try TestSigner().token(issuedAt: now, expiresAt: now.addingTimeInterval(60))
        #expect(throws: CloudFailure.entitlementInvalid) { try check(other) }
    }

    @Test func refusesGarbage() throws {
        for garbage in ["", "a.b", "a.b.c.d", "!!.!!.!!"] {
            #expect(throws: CloudFailure.entitlementInvalid) { try check(garbage) }
        }
    }

    @Test func thePinnedProductionKeyIsAValidEd25519Key() throws {
        _ = try EntitlementVerifier(configuration: .production)
    }
}
