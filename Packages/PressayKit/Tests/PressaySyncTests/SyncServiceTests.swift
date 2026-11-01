// swiftlint:disable cyclomatic_complexity function_body_length large_tuple optional_data_string_conversion trailing_comma
import Foundation
import Testing
@testable import PressayAccount
@testable import PressaySync

/// A sync server in memory, with a second device standing in for the Mac.
final class FakeSyncServer: @unchecked Sendable {
    let lock = NSLock()
    var changes: [[String: Any]] = []
    var accountEnvelope: String?
    var approved = false
    var pending: [[String: Any]] = []
    var recoveryHash: String?
    var recoveryEnvelope: String?
    var nextSequence = 1
    var conflictNextUpload = false

    func handle(_ request: URLRequest, fallback: (URLRequest) throws -> (Int, Data)) throws -> (Int, Data) {
        let path = request.url!.path()
        guard path.hasPrefix("/v1/sync/") else { return try fallback(request) }
        return try lock.withLock {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            switch (request.httpMethod ?? "", path) {
            case ("POST", "/v1/sync/devices/enroll"):
                if accountEnvelope == nil, let envelope = body["encryptedAccountKey"] as? String {
                    accountEnvelope = envelope
                    approved = true
                    return (201, json(#"{"status":"approved"}"#))
                }
                return approved ? (201, json(#"{"status":"approved"}"#)) : (202, json(#"{"status":"pending"}"#))
            case ("GET", "/v1/sync/devices"):
                guard approved else { return (403, json(#"{"error":{"code":"sync_device_not_approved"}}"#)) }
                let current: [String: Any] = [
                    "id": TestIDs.device, "displayName": "Pressay iPhone",
                    "publicKey": Data(repeating: 9, count: 32).base64EncodedString(), "status": "approved",
                ]
                return (200, try JSONSerialization.data(withJSONObject: ["devices": [current] + pending]))
            case let ("GET", envelopePath) where envelopePath.hasSuffix("/envelope"):
                guard approved, let accountEnvelope else { return (403, json(#"{"error":{"code":"sync_envelope_unavailable"}}"#)) }
                return (200, json(#"{"encryptedAccountKey":"\#(accountEnvelope)"}"#))
            case let ("POST", approvePath) where approvePath.hasSuffix("/approve"):
                pending.removeAll()
                return (204, Data())
            case ("PUT", "/v1/sync/recovery"):
                recoveryHash = body["codeHash"] as? String
                recoveryEnvelope = body["encryptedAccountKey"] as? String
                return (204, Data())
            case ("POST", "/v1/sync/recovery/begin"):
                guard body["codeHash"] as? String == recoveryHash, let recoveryEnvelope else {
                    return (403, json(#"{"error":{"code":"sync_recovery_rejected"}}"#))
                }
                return (200, json(#"{"encryptedAccountKey":"\#(recoveryEnvelope)"}"#))
            case ("POST", "/v1/sync/recovery/complete"):
                accountEnvelope = body["encryptedAccountKey"] as? String
                approved = true
                return (204, Data())
            case ("POST", "/v1/sync/changes"):
                let incoming = body["changes"] as? [[String: Any]] ?? []
                for change in incoming {
                    var stored = change
                    stored["sequenceId"] = nextSequence
                    stored["sourceDeviceId"] = body["deviceId"]
                    stored["createdAt"] = "2026-11-01T10:00:00.000Z"
                    stored["conflict"] = false
                    nextSequence += 1
                    changes.append(stored)
                }
                return (201, json(#"{"accepted":\#(incoming.count),"conflicts":0,"cursor":\#(nextSequence - 1)}"#))
            case ("GET", "/v1/sync/changes"):
                let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "after" }!.value!)!
                let page = changes.filter { ($0["sequenceId"] as? Int ?? 0) > after }
                return (200, try JSONSerialization.data(withJSONObject: [
                    "changes": page, "nextCursor": max(after, nextSequence - 1), "hasMore": false,
                ] as [String: Any]))
            default:
                return (500, Data())
            }
        }
    }

    /// Puts a change on the server as the Mac would encrypt it.
    func addFromMac(
        type: SyncObjectType, originalID: String, value: JSONValue, revision: Int, accountKey: Data,
        tombstone: Bool = false, conflict: Bool = false
    ) throws {
        let change = try SyncMerge.encryptedChange(
            SyncMerge.LocalObject(type: type, originalID: originalID, value: value),
            revision: revision, tombstone: tombstone, accountKey: accountKey
        )
        lock.withLock {
            changes.append([
                "objectType": type.rawValue, "objectId": change.objectId, "revision": revision,
                "envelope": change.envelope, "envelopeVersion": 1, "tombstone": tombstone,
                "sequenceId": nextSequence, "sourceDeviceId": TestIDs.otherDevice,
                "createdAt": "2026-11-01T10:00:00.000Z", "conflict": conflict,
            ])
            nextSequence += 1
        }
    }
}

final class MemoryStateStore: SyncStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(accountID: String) throws -> Data? { lock.withLock { values[accountID] } }
    func write(_ data: Data, accountID: String) throws { lock.withLock { values[accountID] = data } }
    func remove(accountID: String) throws { lock.withLock { values[accountID] = nil } }
    var isEmpty: Bool { lock.withLock { values.isEmpty } }
}

@Suite struct SyncServiceTests {
    let cloud = FakeCloud()
    let server = FakeSyncServer()
    let secrets = InMemorySecretStore()
    let stateStore = MemoryStateStore()
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("productivity-\(UUID().uuidString)")

    func make() async throws -> (SyncService, ProductivityStore, AccountService) {
        cloud.transport.setHandler { [server, cloud] request in
            try server.handle(request) { try cloud.answerForTests($0) }
        }
        let account = try cloud.service(secrets: secrets)
        _ = try await cloud.signIn(account)
        let store = ProductivityStore(fileURL: storeURL, secrets: secrets)
        return (SyncService(account: account, secrets: secrets, store: store, stateStore: stateStore), store, account)
    }

    @Test func theFirstDeviceCreatesTheKeyAndUploadsOnlyCiphertext() async throws {
        let (sync, store, _) = try await make()
        try await store.modify { $0.dictionary.append(DictionaryEntry(id: "word-1", term: "Andrieux")) }
        #expect(try await sync.snapshot().status == .notConfigured)
        #expect(try await sync.enable().status == .ready)

        let report = try await sync.run()
        #expect(report.uploaded == 2) // the word and the preference
        let uploaded = server.changes.compactMap { $0["envelope"] as? String }
        #expect(uploaded.count == 2)
        for envelope in uploaded {
            let raw = try #require(Data(base64Encoded: envelope))
            #expect(raw.prefix(8) == Data("PRSYSY01".utf8))
            #expect(String(decoding: raw, as: UTF8.self).contains("Andrieux") == false)
        }
        // A second run has nothing to say.
        #expect(try await sync.run().uploaded == 0)
    }

    @Test func aSecondDeviceWaitsThenJoinsByRecoveryCode() async throws {
        let (sync, _, _) = try await make()
        // The account key already exists elsewhere.
        let accountKey = SyncCrypto.generateAccountKey()
        let recovery = try SyncCrypto.createRecoveryEnvelope(accountKey: accountKey)
        let (code, hash, envelope) = (recovery.code, recovery.hash, recovery.envelope)
        server.lock.withLock {
            server.accountEnvelope = "elsewhere"
            server.recoveryHash = hash.base64EncodedString()
            server.recoveryEnvelope = envelope.base64EncodedString()
        }
        #expect(try await sync.enable().status == .pendingApproval)
        #expect(try await sync.snapshot().status == .pendingApproval)
        await #expect(throws: CloudFailure("cloud_sync_not_ready")) { _ = try await sync.run() }
        await #expect(throws: CloudFailure("cloud_sync_recovery_code_invalid")) { _ = try await sync.recover(code: "nonsense") }

        #expect(try await sync.recover(code: code).status == .ready)
        // Whatever the server now holds, this device can open it itself.
        #expect(try secrets.data(for: "sync-account-key-\(TestIDs.account)") == accountKey)
    }

    func ready() async throws -> (SyncService, ProductivityStore, Data) {
        let (sync, store, _) = try await make()
        #expect(try await sync.enable().status == .ready)
        let key = try #require(try secrets.data(for: "sync-account-key-\(TestIDs.account)"))
        return (sync, store, key)
    }

    @Test func wordsAndModesFromTheMacArrive() async throws {
        let (sync, store, key) = try await ready()
        let word = try JSONValue(encoding: DictionaryEntry(id: "mac-word", term: "Pressay", variants: ["presset"]))
        try server.addFromMac(type: .dictionary, originalID: "mac-word", value: word, revision: 1, accountKey: key)
        let mode: JSONValue = .object([
            "id": .string("mac-mode"), "name": .string("Mine"), "description": .string("x"), "route": .string("local"),
            "steps": .array([.object(["id": .string("t"), "kind": .string("transform"), "instruction": .string("Shorten ${transcript}")])]),
            "future_field": .int(7),
        ])
        try server.addFromMac(type: .mode, originalID: "mac-mode", value: mode, revision: 1, accountKey: key)
        let profile: JSONValue = .object(["id": .string("mac-profile"), "bundle_id": .string("com.apple.mail"), "priority": .int(3)])
        try server.addFromMac(type: .profile, originalID: "mac-profile", value: profile, revision: 1, accountKey: key)

        let report = try await sync.run()
        #expect(report.downloaded == 3)
        let document = await store.document()
        #expect(document.dictionary.map(\.term) == ["Pressay"])
        #expect(document.modes.contains { $0.id == "mac-mode" && $0.instruction == "Shorten ${transcript}" })
        // Kept whole: an iPhone must neither drop a Mac field nor delete a profile.
        #expect(document.customModes[0]["future_field"] == .int(7))
        #expect(document.profiles == [profile])
        let second = try await sync.run()
        #expect(second.uploaded == 0)
        #expect(server.changes.contains { ($0["tombstone"] as? Bool) == true } == false)
    }

    @Test func aMacPreferenceWinsOverAnUntouchedDefault() async throws {
        let (sync, store, key) = try await ready()
        try server.addFromMac(
            type: .preference, originalID: "productivity",
            value: try JSONValue(encoding: SyncedPreferences(activeModeId: "email")), revision: 4, accountKey: key
        )
        let report = try await sync.run()
        #expect(report.conflictsPreserved == 0)
        #expect(await store.document().activeModeID == "email")
        #expect(report.uploaded == 0)
    }

    @Test func aChoiceMadeHereIsNotOverwrittenByAFirstSync() async throws {
        let (sync, store, key) = try await ready()
        try await store.modify { $0.activeModeID = "note" }
        try server.addFromMac(
            type: .preference, originalID: "productivity",
            value: try JSONValue(encoding: SyncedPreferences(activeModeId: "email")), revision: 4, accountKey: key
        )
        _ = try await sync.run()
        #expect(await store.document().activeModeID == "note")
    }

    @Test func aDeletionFromTheMacRemovesAnUnchangedWord() async throws {
        let (sync, store, key) = try await ready()
        let word = try JSONValue(encoding: DictionaryEntry(id: "w", term: "Word"))
        try server.addFromMac(type: .dictionary, originalID: "w", value: word, revision: 1, accountKey: key)
        _ = try await sync.run()
        #expect(await store.document().dictionary.count == 1)
        try server.addFromMac(type: .dictionary, originalID: "w", value: .null, revision: 2, accountKey: key, tombstone: true)
        _ = try await sync.run()
        #expect(await store.document().dictionary.isEmpty)
    }

    @Test func aConflictKeepsBothVersions() async throws {
        let (sync, store, key) = try await ready()
        let shared = DictionaryEntry(id: "w", term: "Word")
        try server.addFromMac(type: .dictionary, originalID: "w", value: try JSONValue(encoding: shared), revision: 1, accountKey: key)
        _ = try await sync.run()
        try await store.modify { $0.dictionary[0].term = "Edited here" }
        var theirs = shared
        theirs.term = "Edited there"
        try server.addFromMac(type: .dictionary, originalID: "w", value: try JSONValue(encoding: theirs), revision: 2, accountKey: key)
        let report = try await sync.run()
        #expect(report.conflictsPreserved == 1)
        let document = await store.document()
        #expect(document.dictionary.contains { $0.term == "Edited here" && $0.enabled })
        #expect(document.dictionary.contains { $0.term == "Edited there" && !$0.enabled && $0.id.contains("-sync-") })
    }

    @Test func aLocalDeletionUploadsATombstone() async throws {
        let (sync, store, _) = try await ready()
        try await store.modify { $0.dictionary.append(DictionaryEntry(id: "w", term: "Word")) }
        _ = try await sync.run()
        try await store.modify { $0.dictionary.removeAll() }
        #expect(try await sync.run().uploaded == 1)
        #expect(server.changes.last?["tombstone"] as? Bool == true)
    }

    @Test func aCorruptEnvelopeStopsTheRunWithoutChangingAnything() async throws {
        let (sync, store, _) = try await ready()
        let otherKey = SyncCrypto.generateAccountKey()
        let word = try JSONValue(encoding: DictionaryEntry(id: "w", term: "Word"))
        try server.addFromMac(type: .dictionary, originalID: "w", value: word, revision: 1, accountKey: otherKey)
        await #expect(throws: CloudFailure("cloud_sync_envelope_invalid")) { _ = try await sync.run() }
        #expect(await store.document().dictionary.isEmpty)
    }

    @Test func approvalAndRecoveryCodeFromThisIPhone() async throws {
        let (sync, _, _) = try await ready()
        let waitingKey = SyncCrypto.generateDeviceKey()
        server.lock.withLock {
            server.pending = [[
                "id": TestIDs.otherDevice, "displayName": "Pressay Mac",
                "publicKey": (try? SyncCrypto.publicKey(forDeviceKey: waitingKey).base64EncodedString()) ?? "",
                "status": "pending",
            ]]
        }
        let snapshot = try await sync.snapshot()
        #expect(snapshot.devices.first { $0.id == TestIDs.otherDevice }?.status == .pendingApproval)
        #expect(snapshot.devices.first { $0.isCurrent }?.status == .ready)
        #expect(try await sync.approve(deviceID: TestIDs.otherDevice).devices.count == 1)
        await #expect(throws: CloudFailure("cloud_sync_device_not_pending")) { _ = try await sync.approve(deviceID: TestIDs.otherDevice) }

        let code = try await sync.createRecoveryCode()
        #expect(code.hasPrefix("PRS1."))
        #expect(server.recoveryEnvelope != nil)
    }

    @Test func forgettingAnAccountRemovesItsKeysAndState() async throws {
        let (sync, _, _) = try await ready()
        _ = try await sync.run()
        await sync.forget(accountID: TestIDs.account)
        #expect(secrets.keys.contains { $0.hasPrefix("sync-") } == false)
        #expect(stateStore.isEmpty)
    }
}
// swiftlint:enable cyclomatic_complexity function_body_length large_tuple optional_data_string_conversion trailing_comma
