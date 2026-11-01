import Foundation
import PressayShared

/// The account of this iPhone: PKCE sign-in, token refresh, the device slot, the signed rights,
/// App Store transactions and deletion. The app works without any of it.
///
/// An actor, and refreshes are shared: a rotating refresh token can be used only once.
public actor AccountService {
    enum Key {
        static let tokens = "oauth-tokens-v1"
        static let entitlement = "entitlement-token-v1"
        static let binding = "account-binding-v1"
        static let deviceIdentifier = "device-identifier-v1"
        /// Remembered past a revocation, to tell this iPhone among the devices to restore.
        static let lastDeviceID = "last-device-id-v1"
    }

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    struct Binding: Codable, Equatable {
        let accountID: String
        let deviceID: String
    }

    /// A generic name: an iPhone's own name often carries a person's name.
    static let deviceDisplayName = "Pressay iPhone"
    static let appVariant = "app_store_ios"
    static let platform = "ios"

    public nonisolated let client: CloudClient
    let secrets: any SecretStore
    let verifier: EntitlementVerifier
    let appVersion: String
    let now: @Sendable () -> Date
    let log: PressayLog?

    var email: String?
    var sessionExpired = false
    var deviceRefusal: AccountSnapshot.Connection?
    var generation = 0
    var refreshTask: Task<String, Error>?

    public init(
        configuration: CloudConfiguration,
        transport: any HTTPTransport,
        secrets: any SecretStore,
        appVersion: String,
        log: PressayLog? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        client = CloudClient(configuration: configuration, transport: transport)
        self.secrets = secrets
        verifier = try EntitlementVerifier(configuration: configuration)
        self.appVersion = appVersion
        self.log = log
        self.now = now
    }

    // MARK: Rights

    /// What the signed rights on this iPhone prove right now. No network: used before each
    /// dictation, and read again each time so an expiry takes effect at once.
    public func cachedSnapshot() -> AccountSnapshot {
        guard let binding = try? load(Binding.self, Key.binding) else {
            let hasSession = (try? secrets.data(for: Key.tokens)) != nil
            guard hasSession else { return .signedOut }
            return AccountSnapshot(connection: deviceRefusal ?? .awaitingDevice, sessionExpired: sessionExpired)
        }
        return AccountSnapshot(
            connection: .connected,
            accountID: binding.accountID,
            deviceID: binding.deviceID,
            email: email,
            entitlement: cachedEntitlement(binding),
            sessionExpired: sessionExpired
        )
    }

    private func cachedEntitlement(_ binding: Binding) -> VerifiedEntitlement? {
        guard let data = try? secrets.data(for: Key.entitlement),
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        do {
            return try verifier.verify(token: token, accountID: binding.accountID, deviceID: binding.deviceID, now: now())
        } catch {
            return nil
        }
    }

    /// Reads the account and the rights from the server. Offline, or while the server is down, the
    /// last signed rights keep working until they expire, exactly as on the Mac.
    public func refresh() async throws -> AccountSnapshot {
        guard let binding = try? load(Binding.self, Key.binding) else {
            guard (try? secrets.data(for: Key.tokens)) != nil else { return .signedOut }
            return try await connectDevice()
        }
        let startedIn = generation
        do {
            let token = try await accessToken()
            let profile = try await client.decode(MeResponse.self, client.request("GET", client.url("/v1/me"), bearer: token))
            guard profile.accountId == binding.accountID else { throw CloudFailure.accountMismatch }
            let rights = try await client.decode(EntitlementResponse.self, client.request(
                "GET", client.url("/v1/entitlements"), bearer: token, headers: ["x-device-id": binding.deviceID]
            ))
            guard rights.signedSnapshot.keyId == client.configuration.entitlementKeyID else {
                throw CloudFailure.entitlementInvalid
            }
            let verified = try verifier.verify(
                token: rights.signedSnapshot.token, accountID: binding.accountID, deviceID: binding.deviceID, now: now()
            )
            guard generation == startedIn else { throw CloudFailure.sessionChanged }
            try secrets.set(Data(rights.signedSnapshot.token.utf8), for: Key.entitlement)
            email = profile.email
            sessionExpired = false
            log?.event("account.refreshed", ["tier": .tag(verified.tier.rawValue), "source": .tag(verified.source.rawValue)])
            return cachedSnapshot()
        } catch let failure as CloudFailure {
            log?.event("account.refreshFailed", ["code": .tag(failure.code)])
            return try await recover(from: failure)
        }
    }

    /// What a failed refresh means for the rights on this iPhone.
    private func recover(from failure: CloudFailure) async throws -> AccountSnapshot {
        if failure.isConnectivity {
            return cachedSnapshot()
        }
        switch failure.code {
        case CloudFailure.sessionExpired.code, "cloud_unauthorized", "unauthorized":
            sessionExpired = true
            return cachedSnapshot()
        case CloudFailure.deviceRevoked.code, "device_not_active":
            // Removed from the account elsewhere: back to Free, and the choice to restore it.
            try? secrets.remove(Key.binding)
            try? secrets.remove(Key.entitlement)
            deviceRefusal = .deviceRevoked
            return cachedSnapshot()
        case CloudFailure.accountNotActive.code, "account_not_found":
            // The account is going away: back to Free, signed out.
            await clearSession(revoking: false)
            throw failure
        default:
            throw failure
        }
    }

    // MARK: Tokens

    public func accessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let tokens = try load(Tokens.self, Key.tokens) else { throw CloudFailure.notConnected }
        if tokens.expiresAt > now().addingTimeInterval(60) {
            return tokens.accessToken
        }
        let task = Task { try await self.performRefresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: Tokens) async throws -> String {
        guard let refreshToken = current.refreshToken else { throw CloudFailure.sessionExpired }
        let startedIn = generation
        let metadata = try await oauthMetadata()
        let response: OAuthTokenResponse
        do {
            response = try await client.decode(OAuthTokenResponse.self, client.form(metadata.tokenEndpoint, [
                ("grant_type", "refresh_token"),
                ("client_id", client.configuration.oauthClientID),
                ("refresh_token", refreshToken),
                ("resource", client.configuration.oauthResource),
            ]))
        } catch let failure as CloudFailure where !failure.isConnectivity {
            throw CloudFailure.sessionExpired
        }
        guard generation == startedIn else { throw CloudFailure.sessionChanged }
        let tokens = try Self.validated(response, previousRefreshToken: refreshToken, now: now())
        try save(tokens, Key.tokens)
        return tokens.accessToken
    }

    static func validated(_ response: OAuthTokenResponse, previousRefreshToken: String?, now: Date) throws -> Tokens {
        guard response.accessToken.count >= 32, response.expiresIn > 0,
              (response.refreshToken?.count ?? 32) >= 32
        else { throw CloudFailure("cloud_auth_token_invalid") }
        return Tokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previousRefreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    func oauthMetadata() async throws -> OAuthMetadata {
        var url = client.configuration.oauthIssuer
        url.append(path: ".well-known/oauth-authorization-server")
        let metadata = try await client.decode(OAuthMetadata.self, client.request("GET", url))
        try client.configuration.validateOAuthEndpoint(metadata.authorizationEndpoint)
        try client.configuration.validateOAuthEndpoint(metadata.tokenEndpoint)
        if let revocation = metadata.revocationEndpoint {
            try client.configuration.validateOAuthEndpoint(revocation)
        }
        return metadata
    }

    // MARK: Storage

    func load<Value: Decodable>(_ type: Value.Type, _ key: String) throws -> Value? {
        guard let data = try secrets.data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save(_ value: some Encodable, _ key: String) throws {
        try secrets.set(JSONEncoder().encode(value), for: key)
    }
}
