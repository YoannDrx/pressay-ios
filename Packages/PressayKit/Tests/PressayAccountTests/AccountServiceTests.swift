// swiftlint:disable line_length trailing_comma
import Foundation
import Testing
@testable import PressayAccount

@Suite struct AccountServiceTests {
    let cloud = FakeCloud()
    let secrets = InMemorySecretStore()

    func signedIn() async throws -> (AccountService, AccountSnapshot) {
        let service = try cloud.service(secrets: secrets)
        return (service, try await cloud.signIn(service))
    }

    // MARK: Sign-in

    @Test func signInFollowsPKCEAndBootstrapsAsAnIPhone() async throws {
        let service = try cloud.service(secrets: secrets)
        let request = try await service.beginSignIn(provider: .apple)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("response_type") == "code")
        #expect(value("redirect_uri") == "pressay://oauth/callback")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == SignInRequest.challenge(for: request.verifier))
        #expect(value("provider") == "apple")
        #expect(value("state") == request.state)
        #expect(request.verifier.count >= 43)

        let callback = URL(string: "pressay://oauth/callback?code=abc&state=\(request.state)")!
        let snapshot = try await service.completeSignIn(request, callback: callback)
        #expect(snapshot.connection == .connected)
        #expect(snapshot.accountID == TestIDs.account)
        #expect(snapshot.email == "person@example.com")

        let tokenRequest = try #require(cloud.transport.requests.first { $0.url?.path() == "/api/auth/oauth2/token" })
        let form = String(data: tokenRequest.httpBody!, encoding: .utf8)!
        #expect(form.contains("code_verifier=\(request.verifier)"))
        #expect(form.contains("grant_type=authorization_code"))

        let bootstrap = try #require(cloud.transport.requests.first { $0.url?.path() == "/v1/accounts/bootstrap" })
        let body = try #require(JSONSerialization.jsonObject(with: bootstrap.httpBody!) as? [String: String])
        #expect(body["platform"] == "ios")
        #expect(body["appVariant"] == "app_store_ios")
        #expect(body["displayName"] == "Pressay iPhone")
        #expect(body["deviceIdentifier"]?.hasPrefix("pressay-device:") == true)
    }

    @Test func aForgedOrDeniedCallbackIsRefused() async throws {
        let service = try cloud.service(secrets: secrets)
        let request = try await service.beginSignIn(provider: nil)
        await #expect(throws: CloudFailure.authStateMismatch) {
            try await service.completeSignIn(request, callback: URL(string: "pressay://oauth/callback?code=abc&state=other")!)
        }
        await #expect(throws: CloudFailure.authDenied) {
            try await service.completeSignIn(request, callback: URL(string: "pressay://oauth/callback?error=denied&state=\(request.state)")!)
        }
        await #expect(throws: CloudFailure.authCallbackInvalid) {
            try await service.completeSignIn(request, callback: URL(string: "evil://oauth/callback?code=abc&state=\(request.state)")!)
        }
        #expect(cloud.transport.paths().contains("POST /api/auth/oauth2/token") == false)
    }

    @Test func anIssuerPointingElsewhereIsRefused() async throws {
        cloud.transport.setHandler { _ in
            (200, json(#"{"authorization_endpoint":"https://evil.example/a","token_endpoint":"https://press-say.app/t"}"#))
        }
        let service = try cloud.service(secrets: secrets)
        await #expect(throws: CloudFailure("cloud_oauth_endpoint_invalid")) {
            _ = try await service.beginSignIn(provider: nil)
        }
    }

    @Test func aCancelledRequestIsNotANetworkFailure() async throws {
        let client = CloudClient(configuration: cloud.signer.configuration, transport: FakeTransport { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { try await client.send(client.request("GET", client.url("/v1/me"))) }
        let offline = CloudClient(configuration: cloud.signer.configuration, transport: FakeTransport { _ in throw URLError(.timedOut) })
        await #expect(throws: CloudFailure.networkUnavailable) { try await offline.send(offline.request("GET", offline.url("/v1/me"))) }
    }

    @Test func serverMessagesNeverReachTheFailure() {
        let failure = CloudClient.failure(status: 409, body: json(#"{"error":{"code":"device_limit_reached","message":"a@b.c"}}"#))
        #expect(failure == .deviceLimitReached)
        #expect(CloudFailure("not a code a@b.c").code == "cloud_request_failed")
    }

    // MARK: Device limit

    @Test func theFourthDeviceKeepsTheSessionAndCanFreeASlot() async throws {
        cloud.update { $0.bootstrapFailure = (409, "device_limit_reached") }
        let (service, snapshot) = try await signedIn()
        #expect(snapshot.connection == .deviceLimitReached)
        #expect(!snapshot.isPro)
        #expect(await service.cachedSnapshot().connection == .deviceLimitReached)

        cloud.update {
            $0.devices = [["id": TestIDs.otherDevice, "displayName": "Pressay Mac", "platform": "macos",
                           "appVariant": "mas", "appVersion": "2", "approved": true,
                           "lastSeenAt": "2026-10-01T10:00:00.000Z", "createdAt": "2026-09-01T10:00:00.000Z"]]
        }
        let devices = try await service.devices()
        #expect(devices.map(\.platform) == ["macos"])
        #expect(devices[0].lastSeen != nil)
        try await service.removeDevice(id: TestIDs.otherDevice)
        #expect(try await service.connectDevice().connection == .connected)
    }

    @Test func theDeviceIdentifierSurvivesASignOut() async throws {
        let (service, _) = try await signedIn()
        let first = try #require(try secrets.data(for: AccountService.Key.deviceIdentifier))
        await service.signOut()
        _ = try await cloud.signIn(service)
        #expect(try secrets.data(for: AccountService.Key.deviceIdentifier) == first)
    }

    /// The cloud refuses a removed device until its owner restores it: the identifier never rotates.
    @Test func aRemovedIPhoneIsOfferedToRestoreItself() async throws {
        let (service, connected) = try await signedIn()
        #expect(connected.connection == .connected)
        let identifier = try #require(try secrets.data(for: AccountService.Key.deviceIdentifier))
        await service.signOut()

        cloud.update {
            $0.bootstrapFailure = (403, "device_revoked")
            $0.revokedDevices = [
                ["id": TestIDs.otherDevice, "displayName": "Pressay Mac", "platform": "macos", "appVariant": "mas",
                 "appVersion": "2", "approved": true, "lastSeenAt": "2026-10-01T10:00:00.000Z",
                 "createdAt": "2026-09-01T10:00:00.000Z", "revokedAt": "2026-10-02T10:00:00.000Z"],
                ["id": TestIDs.device, "displayName": "Pressay iPhone", "platform": "ios", "appVariant": "app_store_ios",
                 "appVersion": "1", "approved": true, "lastSeenAt": "2026-10-01T10:00:00.000Z",
                 "createdAt": "2026-09-01T10:00:00.000Z", "revokedAt": "2026-10-02T10:00:00.000Z"],
            ]
        }
        let refused = try await cloud.signIn(service)
        #expect(refused.connection == .deviceRevoked)
        #expect(!refused.isPro)
        #expect(try secrets.data(for: AccountService.Key.deviceIdentifier) == identifier)

        let revoked = try await service.revokedDevices()
        #expect(revoked.first { $0.isThisIPhone }?.id == TestIDs.device)
        #expect(revoked.filter(\.isThisIPhone).count == 1)
        #expect(cloud.transport.requests.last?.url?.query() == "include=revoked")

        let restored = try await service.restoreDevice(id: TestIDs.device)
        #expect(restored.connection == .connected)
        #expect(cloud.transport.paths().contains("POST /v1/devices/\(TestIDs.device)/restore"))
    }

    @Test func aDeviceRemovedElsewhereFallsBackToFreeWithoutTouchingDictation() async throws {
        cloud.update { $0.tier = "pro"; $0.source = "stripe" }
        let (service, snapshot) = try await signedIn()
        #expect(snapshot.isPro)
        cloud.update { $0.meFailure = (403, "device_revoked") }
        let refreshed = try await service.refresh()
        #expect(refreshed.connection == .deviceRevoked)
        #expect(!refreshed.isPro)
        #expect(try secrets.data(for: AccountService.Key.entitlement) == nil)
        #expect(try secrets.data(for: AccountService.Key.tokens) != nil)
    }

    @Test func anInactiveAccountSignsOut() async throws {
        let (service, _) = try await signedIn()
        cloud.update { $0.meFailure = (403, "account_not_active") }
        await #expect(throws: CloudFailure.accountNotActive) { _ = try await service.refresh() }
        #expect(await service.cachedSnapshot() == .signedOut)
    }

    // MARK: Rights, online and offline

    @Test func aStripeSubscriberSeesProAfterSigningIn() async throws {
        cloud.update { $0.tier = "pro"; $0.source = "stripe" }
        let (_, snapshot) = try await signedIn()
        #expect(snapshot.isPro)
        #expect(snapshot.entitlement?.source == .stripe)
    }

    @Test func proSurvivesOfflineUntilTheSignedRightsExpire() async throws {
        cloud.update { $0.tier = "pro"; $0.source = "app_store" }
        let (service, _) = try await signedIn()
        cloud.update { $0.offline = true; $0.now = $0.now.addingTimeInterval(71 * 3600) }
        let offline = try await service.refresh()
        #expect(offline.isPro)
        #expect(offline.connection == .connected)
        cloud.update { $0.now = $0.now.addingTimeInterval(2 * 3600) }
        let expired = try await service.refresh()
        #expect(!expired.isPro)
        #expect(expired.connection == .connected)
    }

    @Test func aRefusedRefreshTokenKeepsProUntilExpiryAndAsksForASignIn() async throws {
        cloud.update { $0.tier = "pro"; $0.source = "stripe" }
        let (service, _) = try await signedIn()
        cloud.update {
            $0.now = $0.now.addingTimeInterval(2 * 3600)
            $0.tokenFailure = (400, "invalid_grant")
        }
        let snapshot = try await service.refresh()
        #expect(snapshot.sessionExpired)
        #expect(snapshot.isPro)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let (service, _) = try await signedIn()
        let before = cloud.tokenCalls
        cloud.update { $0.now = $0.now.addingTimeInterval(2 * 3600) }
        async let first = service.accessToken()
        async let second = service.accessToken()
        async let third = service.accessToken()
        let tokens = try await [first, second, third]
        #expect(Set(tokens).count == 1)
        #expect(cloud.tokenCalls == before + 1)
    }

    @Test func aTamperedStoredTokenReadsAsFree() async throws {
        cloud.update { $0.tier = "pro"; $0.source = "stripe" }
        let (service, _) = try await signedIn()
        try secrets.set(Data("a.b.c".utf8), for: AccountService.Key.entitlement)
        #expect(await service.cachedSnapshot().isPro == false)
    }

    // MARK: App Store

    @Test func aTransactionIsDeliveredWithItsIdempotencyKey() async throws {
        let (service, _) = try await signedIn()
        let jws = String(repeating: "a", count: 40) + "." + String(repeating: "b", count: 40) + ".sig"
        let snapshot = try await service.deliver(signedTransaction: jws, transactionID: 42, linkToAccount: false)
        #expect(snapshot.isPro)
        let request = try #require(cloud.transport.requests.first { $0.url?.path() == "/v1/billing/restore-app-store" })
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "app-store-transaction-42")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        #expect(body.contains("signedTransaction"))
        #expect(!body.contains("linkToCurrentAccount"))
    }

    @Test func aLinkIsSentOnlyWhenAsked() async throws {
        let (service, _) = try await signedIn()
        let jws = String(repeating: "a", count: 40) + "." + String(repeating: "b", count: 40) + ".sig"
        _ = try await service.deliver(signedTransaction: jws, transactionID: 7, linkToAccount: true)
        let request = try #require(cloud.transport.requests.first { $0.url?.path() == "/v1/billing/restore-app-store" })
        #expect(String(data: request.httpBody!, encoding: .utf8)!.contains(#""linkToCurrentAccount":true"#))
    }

    @Test func aMalformedTransactionNeverLeaves() async throws {
        let (service, _) = try await signedIn()
        await #expect(throws: CloudFailure.transactionInvalid) {
            _ = try await service.deliver(signedTransaction: "short", transactionID: 1, linkToAccount: false)
        }
        #expect(!cloud.transport.paths().contains("POST /v1/billing/restore-app-store"))
    }

    @Test func transactionDecisions() {
        #expect(TransactionDecision.after(nil) == .finish)
        #expect(TransactionDecision.after(CloudFailure("app_store_account_mismatch")) == .askToLink)
        #expect(TransactionDecision.after(CloudFailure("app_store_account_token_missing")) == .askToLink)
        #expect(TransactionDecision.after(CloudFailure("app_store_sandbox_not_allowed")) == .rejected("app_store_sandbox_not_allowed"))
        #expect(TransactionDecision.after(.networkUnavailable) == .retryLater)
        #expect(TransactionDecision.after(.unavailable) == .retryLater)
    }

    // MARK: Deletion

    @Test func deletionAsksWhenAnAppleSubscriptionIsActiveThenCleansUp() async throws {
        cloud.update { $0.deleteFailure = (409, "apple_subscription_active") }
        let (service, _) = try await signedIn()
        await #expect(throws: CloudFailure.appleSubscriptionActive) {
            try await service.deleteAccount(acknowledgingAppleSubscription: false)
        }
        // Nothing happened yet: the account is still there.
        #expect(await service.cachedSnapshot().connection == .connected)

        let deleted = try await service.deleteAccount(acknowledgingAppleSubscription: true)
        #expect(deleted == TestIDs.account)
        #expect(await service.cachedSnapshot() == .signedOut)
        #expect(secrets.keys.sorted() == [AccountService.Key.deviceIdentifier, AccountService.Key.lastDeviceID])
        let request = try #require(cloud.transport.requests.last { $0.httpMethod == "DELETE" })
        #expect(request.url?.query() == "acknowledgeAppleSubscription=true")
    }

    @Test func signOutClearsLocallyEvenOffline() async throws {
        let (service, _) = try await signedIn()
        cloud.update { $0.offline = true }
        await service.signOut()
        #expect(await service.cachedSnapshot() == .signedOut)
    }
}
// swiftlint:enable line_length trailing_comma
