import Foundation
import PressayAccount
import PressayShared

/// End-to-end encrypted sync of the dictionary, modes and the active mode, compatible with the
/// Mac: the server stores opaque envelopes, and only devices of the account can open them. Audio,
/// history and dictated text are never part of it.
public actor SyncService {
    let account: AccountService
    let secrets: any SecretStore
    let store: ProductivityStore
    let stateStore: any SyncStateStoring
    let log: PressayLog?

    public init(
        account: AccountService,
        secrets: any SecretStore,
        store: ProductivityStore,
        stateStore: any SyncStateStoring,
        log: PressayLog? = nil
    ) {
        self.account = account
        self.secrets = secrets
        self.store = store
        self.stateStore = stateStore
        self.log = log
    }

    var client: CloudClient { account.client }

    static func deviceKeyName(_ accountID: String) -> String { "sync-device-key-\(accountID)" }
    static func accountKeyName(_ accountID: String) -> String { "sync-account-key-\(accountID)" }

    func context() async throws -> (accountID: String, deviceID: String) {
        let snapshot = await account.cachedSnapshot()
        guard let accountID = snapshot.accountID, let deviceID = snapshot.deviceID else {
            throw CloudFailure.notConnected
        }
        return (accountID, deviceID)
    }

    private func deviceKey(accountID: String) throws -> Data {
        if let key = try secrets.data(for: Self.deviceKeyName(accountID)) { return key }
        let key = SyncCrypto.generateDeviceKey()
        try secrets.set(key, for: Self.deviceKeyName(accountID))
        return key
    }

    private func accountKey(accountID: String, deviceID: String, deviceKey: Data) async throws -> Data {
        if let key = try secrets.data(for: Self.accountKeyName(accountID)) { return key }
        let response = try await client.decode(SyncEnvelopeResponse.self, client.request(
            "GET", client.url("/v1/sync/devices/\(deviceID)/envelope"), bearer: await account.accessToken()
        ))
        guard let envelope = Data(base64Encoded: response.encryptedAccountKey),
              let key = try? SyncCrypto.openAccountKey(envelope, deviceKey: deviceKey)
        else { throw CloudFailure("cloud_sync_envelope_invalid") }
        try secrets.set(key, for: Self.accountKeyName(accountID))
        return key
    }

    private func listDevices(deviceID: String) async throws -> [SyncDeviceListResponse.Device] {
        try await client.decode(SyncDeviceListResponse.self, client.request(
            "GET",
            client.url("/v1/sync/devices", query: [URLQueryItem(name: "approverDeviceId", value: deviceID)]),
            bearer: await account.accessToken()
        )).devices
    }

    /// Where sync stands. Waiting for approval reads as a state, not as an error.
    public func snapshot() async throws -> SyncSnapshot {
        let (accountID, deviceID) = try await context()
        guard let deviceKey = try secrets.data(for: Self.deviceKeyName(accountID)) else {
            return SyncSnapshot(status: .notConfigured, devices: [])
        }
        do {
            _ = try await accountKey(accountID: accountID, deviceID: deviceID, deviceKey: deviceKey)
            let devices = try await listDevices(deviceID: deviceID)
            return SyncSnapshot(status: .ready, devices: try devices.map { device in
                guard UUID(uuidString: device.id) != nil, Data(base64Encoded: device.publicKey)?.count == 32 else {
                    throw CloudFailure.responseInvalid
                }
                return SyncDevice(
                    id: device.id,
                    displayName: device.displayName,
                    status: device.status == "approved" ? .ready : .pendingApproval,
                    isCurrent: device.id == deviceID
                )
            })
        } catch let failure as CloudFailure where Self.meansPending(failure) {
            return SyncSnapshot(status: .pendingApproval, devices: [])
        }
    }

    private static func meansPending(_ failure: CloudFailure) -> Bool {
        ["cloud_forbidden", "sync_envelope_unavailable", "sync_device_not_approved"].contains(failure.code)
    }

    /// Enrolls this iPhone. The first device of the account creates the account key; any other
    /// waits for an approved device, or for the recovery code.
    public func enable() async throws -> SyncSnapshot {
        let (accountID, deviceID) = try await context()
        let deviceKey = try deviceKey(accountID: accountID)
        let publicKey = try SyncCrypto.publicKey(forDeviceKey: deviceKey)
        let hasAccountKey = try secrets.data(for: Self.accountKeyName(accountID)) != nil
        let candidate = hasAccountKey ? nil : try SyncCrypto.sealAccountKey(SyncCrypto.generateAccountKey(), toPublicKey: publicKey)
        let response = try await client.decode(SyncEnrollResponse.self, client.json(
            "POST",
            client.url("/v1/sync/devices/enroll"),
            body: SyncEnrollRequest(
                deviceId: deviceID,
                publicKey: publicKey.base64EncodedString(),
                encryptedAccountKey: candidate?.base64EncodedString()
            ),
            bearer: await account.accessToken()
        ))
        log?.event("sync.enrolled", ["status": .tag(response.status == "approved" ? "approved" : "pending")])
        switch response.status {
        case "approved": return try await snapshot()
        case "pending": return SyncSnapshot(status: .pendingApproval, devices: [])
        default: throw CloudFailure.responseInvalid
        }
    }

    /// Seals the account key to a waiting device. The server cannot do this.
    public func approve(deviceID target: String) async throws -> SyncSnapshot {
        let (accountID, deviceID) = try await context()
        guard let deviceKey = try secrets.data(for: Self.deviceKeyName(accountID)) else {
            throw CloudFailure("cloud_sync_not_configured")
        }
        let key = try await accountKey(accountID: accountID, deviceID: deviceID, deviceKey: deviceKey)
        let devices = try await listDevices(deviceID: deviceID)
        guard let waiting = devices.first(where: { $0.id == target && $0.status == "pending" }),
              let publicKey = Data(base64Encoded: waiting.publicKey), publicKey.count == 32
        else { throw CloudFailure("cloud_sync_device_not_pending") }
        try await client.send(client.json(
            "POST",
            client.url("/v1/sync/devices/\(target)/approve"),
            body: SyncApproveRequest(
                approverDeviceId: deviceID,
                encryptedAccountKey: try SyncCrypto.sealAccountKey(key, toPublicKey: publicKey).base64EncodedString()
            ),
            bearer: await account.accessToken()
        ))
        return try await snapshot()
    }

    /// A new recovery code, shown once. It replaces the previous one.
    public func createRecoveryCode() async throws -> String {
        let (accountID, deviceID) = try await context()
        guard let deviceKey = try secrets.data(for: Self.deviceKeyName(accountID)) else {
            throw CloudFailure("cloud_sync_not_configured")
        }
        let key = try await accountKey(accountID: accountID, deviceID: deviceID, deviceKey: deviceKey)
        let recovery = try SyncCrypto.createRecoveryEnvelope(accountKey: key)
        let (code, hash, envelope) = (recovery.code, recovery.hash, recovery.envelope)
        try await client.send(client.json(
            "PUT",
            client.url("/v1/sync/recovery"),
            body: SyncRecoveryRequest(
                deviceId: deviceID, codeHash: hash.base64EncodedString(), encryptedAccountKey: envelope.base64EncodedString()
            ),
            bearer: await account.accessToken()
        ))
        return code
    }

    /// Joins with a recovery code made on another device, which then needs no approval.
    public func recover(code: String) async throws -> SyncSnapshot {
        let (accountID, deviceID) = try await context()
        let deviceKey = try deviceKey(accountID: accountID)
        let publicKey = try SyncCrypto.publicKey(forDeviceKey: deviceKey)
        guard let hash = try? SyncCrypto.recoveryCodeHash(code) else {
            throw CloudFailure("cloud_sync_recovery_code_invalid")
        }
        let response = try await client.decode(SyncEnvelopeResponse.self, client.json(
            "POST",
            client.url("/v1/sync/recovery/begin"),
            body: SyncBeginRecoveryRequest(
                deviceId: deviceID, publicKey: publicKey.base64EncodedString(), codeHash: hash.base64EncodedString()
            ),
            bearer: await account.accessToken()
        ))
        guard let envelope = Data(base64Encoded: response.encryptedAccountKey),
              let key = try? SyncCrypto.openRecoveryEnvelope(code: code, envelope: envelope)
        else { throw CloudFailure("cloud_sync_recovery_code_invalid") }
        let sealed = try SyncCrypto.sealAccountKey(key, toPublicKey: publicKey)
        try secrets.set(key, for: Self.accountKeyName(accountID))
        try await client.send(client.json(
            "POST",
            client.url("/v1/sync/recovery/complete"),
            body: SyncRecoveryRequest(
                deviceId: deviceID, codeHash: hash.base64EncodedString(), encryptedAccountKey: sealed.base64EncodedString()
            ),
            bearer: await account.accessToken()
        ))
        return try await snapshot()
    }

    /// After an account deletion: its keys and revisions have no further use.
    public func forget(accountID: String) {
        try? secrets.remove(Self.deviceKeyName(accountID))
        try? secrets.remove(Self.accountKeyName(accountID))
        try? stateStore.remove(accountID: accountID)
    }
}
