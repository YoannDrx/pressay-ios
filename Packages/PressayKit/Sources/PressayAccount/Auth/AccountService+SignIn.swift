import Foundation
import PressayShared

/// PKCE sign-in and the device slot.
extension AccountService {
    public func beginSignIn(provider: SignInProvider?) async throws -> SignInRequest {
        let metadata = try await oauthMetadata()
        let state = SignInRequest.randomToken()
        let verifier = SignInRequest.randomToken()
        let url = try SignInRequest.authorizationURL(
            endpoint: metadata.authorizationEndpoint,
            configuration: client.configuration,
            provider: provider,
            state: state,
            verifier: verifier
        )
        return SignInRequest(url: url, state: state, verifier: verifier, tokenEndpoint: metadata.tokenEndpoint, createdAt: now())
    }

    /// Finishes an attempt with the callback URL. The session is kept even when the account has no
    /// free device slot: the user can then free one from this iPhone.
    public func completeSignIn(_ request: SignInRequest, callback: URL) async throws -> AccountSnapshot {
        let code = try request.code(fromCallback: callback, now: now())
        let response: OAuthTokenResponse = try await client.decode(
            OAuthTokenResponse.self,
            client.form(request.tokenEndpoint, [
                ("grant_type", "authorization_code"),
                ("client_id", client.configuration.oauthClientID),
                ("code", code),
                ("code_verifier", request.verifier),
                ("redirect_uri", CloudConfiguration.redirectURI),
                ("resource", client.configuration.oauthResource),
            ])
        )
        generation += 1
        sessionExpired = false
        try save(Self.validated(response, previousRefreshToken: nil, now: now()), Key.tokens)
        // A sign-in replaces whatever account was bound before.
        try secrets.remove(Key.binding)
        try secrets.remove(Key.entitlement)
        return try await connectDevice()
    }

    /// Takes a device slot, then reads the rights. Asked again after a slot was freed or this iPhone
    /// restored. A refusal is a state, not a failure: the session stays, and the choice is offered.
    public func connectDevice() async throws -> AccountSnapshot {
        do {
            try await bootstrap()
        } catch let failure as CloudFailure where failure == .deviceLimitReached {
            log?.event("account.deviceLimit")
            deviceRefusal = .deviceLimitReached
            return cachedSnapshot()
        } catch let failure as CloudFailure where failure == .deviceRevoked {
            log?.event("account.deviceRevoked")
            deviceRefusal = .deviceRevoked
            return cachedSnapshot()
        }
        return try await refresh()
    }

    func bootstrap() async throws {
        let startedIn = generation
        let token = try await accessToken()
        let response = try await client.decode(
            BootstrapResponse.self,
            client.json("POST", client.url("/v1/accounts/bootstrap"), body: BootstrapRequest(
                deviceIdentifier: try deviceIdentifier(),
                displayName: Self.deviceDisplayName,
                appVariant: Self.appVariant,
                appVersion: appVersion,
                platform: Self.platform
            ), bearer: token)
        )
        guard generation == startedIn else { throw CloudFailure.sessionChanged }
        guard UUID(uuidString: response.accountId) != nil, UUID(uuidString: response.device.id) != nil else {
            throw CloudFailure.responseInvalid
        }
        deviceRefusal = nil
        try save(Binding(accountID: response.accountId, deviceID: response.device.id), Key.binding)
        try secrets.set(Data(response.device.id.utf8), for: Key.lastDeviceID)
    }

    /// Kept across sign-outs and reinstalls, so this iPhone keeps one device slot.
    func deviceIdentifier() throws -> String {
        if let data = try secrets.data(for: Key.deviceIdentifier), let value = String(data: data, encoding: .utf8) {
            return value
        }
        let value = "pressay-device:\(UUID().uuidString.lowercased())"
        try secrets.set(Data(value.utf8), for: Key.deviceIdentifier)
        return value
    }
}
