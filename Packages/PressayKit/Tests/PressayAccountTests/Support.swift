// swiftlint:disable cyclomatic_complexity function_body_length
import CryptoKit
import Foundation
@testable import PressayAccount

/// A scripted server. Unknown routes answer 500, so an unexpected call fails the test.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler = { _ in (500, Data()) }) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func paths() -> [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = lock.withLock {
            recorded.append(request)
            return self.handler
        }
        let (status, data) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

func json(_ text: String) -> Data { Data(text.utf8) }

/// A signer standing in for the cloud's entitlement key.
struct TestSigner {
    let key = Curve25519.Signing.PrivateKey()
    let keyID = "test-key"

    var configuration: CloudConfiguration {
        CloudConfiguration(
            apiBaseURL: URL(string: "https://api.press-say.app")!,
            oauthIssuer: URL(string: "https://press-say.app")!,
            oauthClientID: "client",
            oauthResource: "https://api.press-say.app",
            entitlementKeyID: keyID,
            entitlementPublicKey: key.publicKey.rawRepresentation.base64URL,
            entitlementIssuer: "https://api.press-say.app"
        )
    }

    func token(
        tier: String = "pro",
        source: String = "app_store",
        accountID: String = TestIDs.account,
        deviceID: String = TestIDs.device,
        audience: [String] = ["app.pressay.desktop", "fr.yodev.pressay"],
        issuer: String = "https://api.press-say.app",
        issuedAt: Date,
        expiresAt: Date,
        keyID: String? = nil,
        alg: String = "EdDSA"
    ) throws -> String {
        let header: [String: Any] = ["alg": alg, "kid": keyID ?? self.keyID, "typ": "JWT"]
        let claims: [String: Any] = [
            "tier": tier,
            "source": source,
            "revision": 3,
            "device_id": deviceID,
            "online_valid_until": expiresAt.timeIntervalSince1970,
            "offline_grace_until": expiresAt.timeIntervalSince1970,
            "usage": ["period_start": "2026-11-01"],
            "iss": issuer,
            "aud": audience,
            "sub": accountID,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        let head = try JSONSerialization.data(withJSONObject: header).base64URL
        let body = try JSONSerialization.data(withJSONObject: claims).base64URL
        let signature = try key.signature(for: Data("\(head).\(body)".utf8))
        return "\(head).\(body).\(signature.base64URL)"
    }
}

enum TestIDs {
    static let account = "6f1c1f3e-4b7a-4d62-9a11-0f6a0f6a0f6a"
    static let device = "2b4c6d8e-1a3b-4c5d-8e7f-1a2b3c4d5e6f"
    static let otherDevice = "aaaaaaaa-1a3b-4c5d-8e7f-1a2b3c4d5e6f"
}

/// The whole cloud for one account, scripted around a signer.
final class FakeCloud: @unchecked Sendable {
    let transport = FakeTransport()
    let signer = TestSigner()
    let lock = NSLock()
    var now: Date
    var tier = "free"
    var source = "none"
    var offline = false
    var bootstrapFailure: (Int, String)?
    var deleteFailure: (Int, String)?
    var meFailure: (Int, String)?
    var restoreFailure: (Int, String)?
    var tokenFailure: (Int, String)?
    var tokenCalls = 0
    var devices: [[String: Any]] = []
    var revokedDevices: [[String: Any]] = []

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
        transport.setHandler { [unowned self] request in try self.answer(request) }
    }

    private func error(_ status: Int, _ code: String) -> (Int, Data) {
        (status, json(#"{"error":{"code":"\#(code)","message":"secret message user@example.com"}}"#))
    }

    /// The regular answers, for a test that overrides one route.
    func answerForTests(_ request: URLRequest) throws -> (Int, Data) {
        try answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            if offline { throw URLError(.notConnectedToInternet) }
            let path = request.url!.path()
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/.well-known/oauth-authorization-server"):
                return (200, json("""
                {"authorization_endpoint":"https://press-say.app/api/auth/oauth2/authorize",\
                "token_endpoint":"https://press-say.app/api/auth/oauth2/token",\
                "revocation_endpoint":"https://press-say.app/api/auth/oauth2/revoke"}
                """))
            case ("POST", "/api/auth/oauth2/token"):
                tokenCalls += 1
                if let tokenFailure { return (tokenFailure.0, json(#"{"error":"\#(tokenFailure.1)"}"#)) }
                return (200, json("""
                {"access_token":"access-\(tokenCalls)-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\
                "refresh_token":"refresh-\(tokenCalls)-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expires_in":3600}
                """))
            case ("POST", "/api/auth/oauth2/revoke"):
                return (200, Data())
            case ("POST", "/v1/accounts/bootstrap"):
                if let bootstrapFailure { return error(bootstrapFailure.0, bootstrapFailure.1) }
                return (200, json(#"{"accountId":"\#(TestIDs.account)","created":false,"device":{"id":"\#(TestIDs.device)"}}"#))
            case ("GET", "/v1/me"):
                if let meFailure { return error(meFailure.0, meFailure.1) }
                return (200, json(#"{"accountId":"\#(TestIDs.account)","email":"person@example.com","status":"active"}"#))
            case ("GET", "/v1/entitlements"):
                let token = try signer.token(tier: tier, source: source, issuedAt: now, expiresAt: now.addingTimeInterval(72 * 3600))
                return (200, json(#"{"signedSnapshot":{"token":"\#(token)","keyId":"\#(signer.keyID)","expiresAt":"x"}}"#))
            case ("POST", "/v1/billing/restore-app-store"):
                if let restoreFailure { return error(restoreFailure.0, restoreFailure.1) }
                tier = "pro"
                source = "app_store"
                return (200, json(#"{"restored":true}"#))
            case ("DELETE", "/v1/me"):
                if let deleteFailure, request.url?.query()?.contains("acknowledgeAppleSubscription=true") != true {
                    return error(deleteFailure.0, deleteFailure.1)
                }
                return (202, Data())
            case ("GET", "/v1/devices"):
                var body: [String: Any] = ["devices": devices, "limit": 3]
                if request.url?.query() == "include=revoked" { body["revokedDevices"] = revokedDevices }
                return (200, try JSONSerialization.data(withJSONObject: body))
            case let ("POST", restorePath) where restorePath.hasSuffix("/restore"):
                bootstrapFailure = nil
                return (200, json("{}"))
            case let ("DELETE", devicePath) where devicePath.hasPrefix("/v1/devices/"):
                bootstrapFailure = nil
                return (204, Data())
            default:
                return (500, Data())
            }
        }
    }

    func update(_ body: (FakeCloud) -> Void) {
        lock.withLock { body(self) }
    }

    /// An account service signed in against this cloud, with a clock this cloud controls.
    func service(secrets: InMemorySecretStore = InMemorySecretStore()) throws -> AccountService {
        try AccountService(
            configuration: signer.configuration,
            transport: transport,
            secrets: secrets,
            appVersion: "1.0.0",
            now: { [unowned self] in self.lock.withLock { self.now } }
        )
    }

    func signIn(_ service: AccountService) async throws -> AccountSnapshot {
        let request = try await service.beginSignIn(provider: .apple)
        let callback = URL(string: "pressay://oauth/callback?code=abc&state=\(request.state)")!
        return try await service.completeSignIn(request, callback: callback)
    }
}
// swiftlint:enable cyclomatic_complexity function_body_length
