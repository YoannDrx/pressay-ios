import Foundation
import PressayShared

/// Devices, App Store transactions and leaving.
extension AccountService {
    // MARK: Devices

    public func devices() async throws -> [AccountDevice] {
        let token = try await accessToken()
        return try await client.decode(
            DeviceListResponse.self, client.request("GET", client.url("/v1/devices"), bearer: token)
        ).devices
    }

    /// Devices removed from the account, which their owner can bring back.
    public func revokedDevices() async throws -> [RevokedDevice] {
        let token = try await accessToken()
        let lastID = (try? secrets.data(for: Key.lastDeviceID)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
        let response = try await client.decode(DeviceListResponse.self, client.request(
            "GET", client.url("/v1/devices", query: [URLQueryItem(name: "include", value: "revoked")]), bearer: token
        ))
        return (response.revokedDevices ?? []).map { RevokedDevice(device: $0, isThisIPhone: $0.id == lastID) }
    }

    /// Brings a removed device back, within the three active devices, then reconnects this iPhone.
    public func restoreDevice(id: String) async throws -> AccountSnapshot {
        guard UUID(uuidString: id) != nil else { throw CloudFailure("invalid_device_id") }
        let token = try await accessToken()
        try await client.send(client.request("POST", client.url("/v1/devices/\(id)/restore"), bearer: token))
        return try await connectDevice()
    }

    public func removeDevice(id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw CloudFailure("invalid_device_id") }
        let token = try await accessToken()
        try await client.send(client.request("DELETE", client.url("/v1/devices/\(id)"), bearer: token))
    }

    // MARK: App Store

    /// Hands a signed transaction to the cloud, which verifies it with Apple and grants Pro. The
    /// idempotency key is per transaction, so a retry after a lost response cannot double anything.
    public func deliver(signedTransaction: String, transactionID: UInt64, linkToAccount: Bool) async throws -> AccountSnapshot {
        guard (64...250_000).contains(signedTransaction.utf8.count), signedTransaction.split(separator: ".").count == 3 else {
            throw CloudFailure.transactionInvalid
        }
        let token = try await accessToken()
        let response = try await client.decode(RestoreAppStoreResponse.self, client.json(
            "POST",
            client.url("/v1/billing/restore-app-store"),
            body: RestoreAppStoreRequest(signedTransaction: signedTransaction, linkToCurrentAccount: linkToAccount ? true : nil),
            bearer: token,
            headers: ["Idempotency-Key": "app-store-transaction-\(transactionID)"]
        ))
        guard response.restored else { throw CloudFailure("storekit_restore_failed") }
        return try await refresh()
    }

    public func billingStatus() async throws -> BillingStatus {
        let token = try await accessToken()
        return try await client.decode(BillingStatus.self, client.request("GET", client.url("/v1/billing/status"), bearer: token))
    }

    // MARK: Leaving

    /// Local credentials go whatever the network does; revoking the refresh token is best effort.
    public func signOut() async {
        await clearSession(revoking: true)
    }

    /// Asks the cloud to delete the account. `apple_subscription_active` means an App Store
    /// subscription would keep billing: the user chooses, then calls again with `acknowledging`.
    /// Returns the deleted account's identifier, so its local sync data can go too.
    @discardableResult
    public func deleteAccount(acknowledgingAppleSubscription acknowledging: Bool) async throws -> String? {
        let accountID = (try? load(Binding.self, Key.binding))?.accountID
        let token = try await accessToken()
        let query = acknowledging ? [URLQueryItem(name: "acknowledgeAppleSubscription", value: "true")] : []
        try await client.send(client.request("DELETE", client.url("/v1/me", query: query), bearer: token))
        await clearSession(revoking: true)
        log?.event("account.deleted")
        return accountID
    }

    func clearSession(revoking: Bool) async {
        generation += 1
        refreshTask = nil
        email = nil
        sessionExpired = false
        deviceRefusal = nil
        let tokens = try? load(Tokens.self, Key.tokens)
        for key in [Key.tokens, Key.entitlement, Key.binding] {
            try? secrets.remove(key)
        }
        if revoking, let refreshToken = tokens?.refreshToken {
            await revoke(refreshToken)
        }
    }

    private func revoke(_ refreshToken: String) async {
        do {
            guard let endpoint = try await oauthMetadata().revocationEndpoint else { return }
            try await client.send(client.form(endpoint, [
                ("token", refreshToken),
                ("token_type_hint", "refresh_token"),
                ("client_id", client.configuration.oauthClientID),
            ]))
        } catch {
            log?.event("account.revokeFailed")
        }
    }

    /// A reinstall keeps the Keychain: a fresh install starts signed out, with the same device slot.
    public func clearSessionAfterReinstall() {
        for key in [Key.tokens, Key.entitlement, Key.binding] {
            try? secrets.remove(key)
        }
    }
}
