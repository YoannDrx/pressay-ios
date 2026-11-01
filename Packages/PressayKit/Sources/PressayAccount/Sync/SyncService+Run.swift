import Foundation
import PressayShared

/// What one page of changes did.
private struct PageResult: Sendable {
    let state: SyncLocalState
    let downloaded: Int
    let conflicts: Int
}

extension SyncService {
    /// One sync run: pull, upload what changed here, then pull again. A device approved but still
    /// not holding the key reads as `cloud_sync_not_ready`.
    public func run() async throws -> SyncRunReport {
        let (accountID, deviceID) = try await context()
        guard try secrets.data(for: Self.deviceKeyName(accountID)) != nil else {
            throw CloudFailure("cloud_sync_not_configured")
        }
        guard let key = try secrets.data(for: Self.accountKeyName(accountID)) else {
            throw CloudFailure("cloud_sync_not_ready")
        }
        var state = try readState(accountID: accountID)
        var (downloaded, conflicts) = try await pull(state: &state, accountKey: key, deviceID: deviceID, accountID: accountID)
        try writeState(state)

        let document = await store.document()
        let (changes, entries) = try SyncMerge.pendingChanges(document, state: state, accountKey: key)
        var uploaded = 0
        for start in stride(from: 0, to: changes.count, by: 100) {
            let batch = Array(changes[start..<min(start + 100, changes.count)])
            let response = try await client.decode(AppendSyncChangesResponse.self, client.json(
                "POST",
                client.url("/v1/sync/changes"),
                body: AppendSyncChangesRequest(deviceId: deviceID, changes: batch),
                bearer: await account.accessToken()
            ))
            uploaded += response.accepted
            conflicts += response.conflicts
        }
        if !changes.isEmpty {
            state.entries = entries
            try writeState(state)
            let (more, moreConflicts) = try await pull(state: &state, accountKey: key, deviceID: deviceID, accountID: accountID)
            downloaded += more
            conflicts += moreConflicts
        }
        try writeState(state)
        log?.event("sync.done", ["uploaded": .int(uploaded), "downloaded": .int(downloaded), "conflicts": .int(conflicts)])
        return SyncRunReport(uploaded: uploaded, downloaded: downloaded, conflictsPreserved: conflicts, nextCursor: state.cursor)
    }

    private func pull(state: inout SyncLocalState, accountKey: Data, deviceID: String, accountID: String) async throws -> (Int, Int) {
        var downloaded = 0
        var conflicts = 0
        while true {
            let page = try await client.decode(SyncChangesResponse.self, client.request(
                "GET",
                client.url("/v1/sync/changes", query: [
                    URLQueryItem(name: "deviceId", value: deviceID),
                    URLQueryItem(name: "after", value: String(state.cursor)),
                    URLQueryItem(name: "limit", value: "200"),
                ]),
                bearer: await account.accessToken()
            ))
            // The user may sign out while the request is in flight.
            guard await account.cachedSnapshot().accountID == accountID else { throw CloudFailure.accountMismatch }
            let result = try await store.modify { [state] document in
                var current = state
                var downloaded = 0
                var conflicts = 0
                for change in page.changes {
                    guard UUID(uuidString: change.sourceDeviceId) != nil, UUID(uuidString: change.objectId) != nil else {
                        throw CloudFailure.responseInvalid
                    }
                    if change.sourceDeviceId.lowercased() != deviceID.lowercased() {
                        let payload = try SyncMerge.decrypt(change, accountKey: accountKey)
                        if try SyncMerge.apply(change, payload: payload, to: &document, state: &current) {
                            conflicts += 1
                        }
                        downloaded += 1
                    }
                    current.cursor = max(current.cursor, change.sequenceId)
                }
                current.cursor = max(current.cursor, page.nextCursor)
                return PageResult(state: current, downloaded: downloaded, conflicts: conflicts)
            }
            state = result.state
            downloaded += result.downloaded
            conflicts += result.conflicts
            guard page.hasMore else { return (downloaded, conflicts) }
        }
    }

    private func readState(accountID: String) throws -> SyncLocalState {
        guard let data = try stateStore.read(accountID: accountID) else { return SyncLocalState(accountID: accountID) }
        guard let state = try? JSONDecoder().decode(SyncLocalState.self, from: data),
              state.schemaVersion == SyncLocalState.currentSchema, state.accountID == accountID
        else { throw CloudFailure("cloud_sync_state_invalid") }
        return state
    }

    private func writeState(_ state: SyncLocalState) throws {
        try stateStore.write(JSONEncoder().encode(state), accountID: state.accountID)
    }
}
