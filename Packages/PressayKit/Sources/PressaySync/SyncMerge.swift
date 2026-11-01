import Foundation
import PressayAccount

/// The Mac's merge rules (`cloud_sync.rs`), free of any network: what to upload, and how to apply
/// what arrives. A conflict never loses work: the other side's version is kept next to this one.
enum SyncMerge {
    struct LocalObject {
        let type: SyncObjectType
        let originalID: String
        let value: JSONValue
    }

    static func localObjects(_ document: ProductivityDocument) throws -> [LocalObject] {
        var objects: [LocalObject] = []
        for mode in document.customModes {
            guard let id = mode["id"]?.stringValue else { continue }
            objects.append(LocalObject(type: .mode, originalID: id, value: mode))
        }
        for profile in document.profiles {
            guard let id = profile["id"]?.stringValue else { continue }
            objects.append(LocalObject(type: .profile, originalID: id, value: profile))
        }
        for entry in document.dictionary {
            objects.append(LocalObject(type: .dictionary, originalID: entry.id, value: try JSONValue(encoding: entry)))
        }
        objects.append(LocalObject(
            type: .preference,
            originalID: SyncFormat.preferenceID,
            value: try JSONValue(encoding: SyncedPreferences(activeModeId: document.activeModeID))
        ))
        return objects
    }

    static func encryptedChange(_ object: LocalObject, revision: Int, tombstone: Bool, accountKey: Data) throws -> SyncChangeInput {
        let objectID = SyncFormat.objectUUID(object.type, object.originalID)
        let payload = EncryptedPayload(
            schemaVersion: SyncFormat.schemaVersion,
            objectType: object.type,
            originalId: object.originalID,
            value: tombstone ? .null : object.value
        )
        let envelope = try SyncCrypto.encryptChange(
            JSONEncoder().encode(payload),
            accountKey: accountKey,
            aad: SyncFormat.aad(object.type, objectID: objectID, revision: revision, envelopeVersion: SyncFormat.envelopeVersion)
        )
        guard envelope.count <= SyncFormat.maximumEnvelopeBytes else { throw CloudFailure("cloud_sync_payload_too_large") }
        return SyncChangeInput(
            objectType: object.type,
            objectId: objectID,
            revision: revision,
            envelope: envelope.base64EncodedString(),
            envelopeVersion: SyncFormat.envelopeVersion,
            tombstone: tombstone
        )
    }

    static func pendingChanges(
        _ document: ProductivityDocument,
        state: SyncLocalState,
        accountKey: Data
    ) throws -> (changes: [SyncChangeInput], entries: [String: SyncLocalState.Entry]) {
        let objects = try localObjects(document)
        let present = Set(objects.map { SyncFormat.stateKey($0.type, $0.originalID) })
        var next = state.entries
        var changes: [SyncChangeInput] = []
        for object in objects {
            let key = SyncFormat.stateKey(object.type, object.originalID)
            let hash = try SyncFormat.hash(object.value)
            let previous = state.entries[key] ?? SyncLocalState.Entry()
            if previous.hash != hash || previous.tombstone {
                let revision = max(1, previous.revision + 1)
                changes.append(try encryptedChange(object, revision: revision, tombstone: false, accountKey: accountKey))
                next[key] = SyncLocalState.Entry(revision: revision, hash: hash, tombstone: false)
            }
        }
        for (key, previous) in state.entries.sorted(by: { $0.key < $1.key }) where !present.contains(key) && !previous.tombstone {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let type = SyncObjectType(rawValue: parts[0]) else {
                throw CloudFailure("cloud_sync_state_invalid")
            }
            let revision = max(1, previous.revision + 1)
            let object = LocalObject(type: type, originalID: parts[1], value: .null)
            changes.append(try encryptedChange(object, revision: revision, tombstone: true, accountKey: accountKey))
            next[key] = SyncLocalState.Entry(revision: revision, hash: try SyncFormat.hash(.null), tombstone: true)
        }
        return (changes, next)
    }

    static func decrypt(_ change: SyncChangeOutput, accountKey: Data) throws -> EncryptedPayload {
        guard change.envelopeVersion == SyncFormat.envelopeVersion, change.envelope.count <= 1_500_000,
              let envelope = Data(base64Encoded: change.envelope),
              let plain = try? SyncCrypto.decryptChange(
                  envelope,
                  accountKey: accountKey,
                  aad: SyncFormat.aad(
                      change.objectType, objectID: change.objectId, revision: change.revision, envelopeVersion: change.envelopeVersion
                  )
              )
        else { throw CloudFailure("cloud_sync_envelope_invalid") }
        guard let payload = try? JSONDecoder().decode(EncryptedPayload.self, from: plain),
              payload.schemaVersion == SyncFormat.schemaVersion,
              payload.objectType == change.objectType,
              SyncFormat.objectUUID(payload.objectType, payload.originalId) == change.objectId,
              change.tombstone == (payload.value == .null)
        else { throw CloudFailure("cloud_sync_payload_invalid") }
        return payload
    }

    private static func remove(_ type: SyncObjectType, id: String, from document: inout ProductivityDocument) {
        switch type {
        case .mode: document.customModes.removeAll { $0["id"]?.stringValue == id }
        case .profile: document.profiles.removeAll { $0["id"]?.stringValue == id }
        case .dictionary: document.dictionary.removeAll { $0.id == id }
        case .preference: break
        }
    }

    /// Returns true when a conflict was preserved.
    static func apply(
        _ change: SyncChangeOutput,
        payload: EncryptedPayload,
        to document: inout ProductivityDocument,
        state: inout SyncLocalState
    ) throws -> Bool {
        let key = SyncFormat.stateKey(change.objectType, payload.originalId)
        let previous = state.entries[key] ?? SyncLocalState.Entry()
        if change.revision < previous.revision { return false }
        let local = try localObjects(document).first { $0.type == change.objectType && $0.originalID == payload.originalId }
        let localHash = try local.map { try SyncFormat.hash($0.value) }
        // A preference nobody has touched on this iPhone is not a choice worth defending: without
        // this, a first sync would answer the Mac's active mode with the default one.
        let untouchedDefault = change.objectType == .preference && previous.revision == 0
            && document.activeModeID == PressayMode.faithfulID
        let locallyUnchanged = localHash == previous.hash || (local == nil && previous.tombstone) || untouchedDefault

        if change.tombstone {
            return try applyTombstone(
                change, key: key, previous: previous, locallyUnchanged: locallyUnchanged,
                to: &document, state: &state, id: payload.originalId
            )
        }

        let remoteHash = try SyncFormat.hash(payload.value)
        if localHash == remoteHash {
            state.entries[key] = SyncLocalState.Entry(
                revision: max(change.revision, previous.revision), hash: remoteHash, tombstone: false
            )
            return false
        }
        let preserveConflict = change.conflict || (!locallyUnchanged && local != nil)
        try merge(change, payload: payload, preserveConflict: preserveConflict, into: &document)
        let currentHash = try localObjects(document)
            .first { $0.type == change.objectType && $0.originalID == payload.originalId }
            .map { try SyncFormat.hash($0.value) }
        state.entries[key] = SyncLocalState.Entry(
            revision: max(change.revision, previous.revision),
            hash: preserveConflict ? remoteHash : (currentHash ?? remoteHash),
            tombstone: false
        )
        return preserveConflict
    }

    // swiftlint:disable:next function_parameter_count
    private static func applyTombstone(
        _ change: SyncChangeOutput,
        key: String,
        previous: SyncLocalState.Entry,
        locallyUnchanged: Bool,
        to document: inout ProductivityDocument,
        state: inout SyncLocalState,
        id: String
    ) throws -> Bool {
        if !change.conflict, locallyUnchanged || previous.revision == 0 {
            remove(change.objectType, id: id, from: &document)
            state.entries[key] = SyncLocalState.Entry(revision: change.revision, hash: try SyncFormat.hash(.null), tombstone: true)
            return false
        }
        state.entries[key] = SyncLocalState.Entry(
            revision: max(change.revision, previous.revision), hash: try SyncFormat.hash(.null), tombstone: false
        )
        return true
    }

    private static func merge(
        _ change: SyncChangeOutput,
        payload: EncryptedPayload,
        preserveConflict: Bool,
        into document: inout ProductivityDocument
    ) throws {
        let conflictID = preserveConflict
            ? SyncFormat.conflictID(payload.originalId, sourceDeviceID: change.sourceDeviceId, revision: change.revision)
            : nil
        switch change.objectType {
        case .mode:
            try merge(mode: payload.value, id: payload.originalId, conflictID: conflictID, into: &document)
        case .profile:
            try merge(profile: payload.value, id: payload.originalId, conflictID: conflictID, into: &document)
        case .dictionary:
            guard var entry = try? payload.value.decoded(as: DictionaryEntry.self), entry.isValid else {
                throw CloudFailure("cloud_sync_payload_invalid")
            }
            if let conflictID {
                entry.id = conflictID
                entry.enabled = false
            }
            remove(.dictionary, id: entry.id, from: &document)
            document.dictionary.append(entry)
        case .preference:
            guard let preferences = try? payload.value.decoded(as: SyncedPreferences.self) else {
                throw CloudFailure("cloud_sync_payload_invalid")
            }
            if !preserveConflict, document.modes.contains(where: { $0.id == preferences.activeModeId }) {
                document.activeModeID = preferences.activeModeId
            }
        }
    }

    private static func merge(mode value: JSONValue, id: String, conflictID: String?, into document: inout ProductivityDocument) throws {
        var mode = value
        guard mode["id"]?.stringValue == id, DictionaryEntry.isValidID(id), mode["name"]?.stringValue != nil else {
            throw CloudFailure("cloud_sync_payload_invalid")
        }
        if let conflictID {
            mode["id"] = .string(conflictID)
            mode["is_builtin"] = .bool(false)
        }
        remove(.mode, id: conflictID ?? id, from: &document)
        document.customModes.append(mode)
    }

    private static func merge(profile value: JSONValue, id: String, conflictID: String?, into document: inout ProductivityDocument) throws {
        var profile = value
        guard profile["id"]?.stringValue == id, DictionaryEntry.isValidID(id) else {
            throw CloudFailure("cloud_sync_payload_invalid")
        }
        if let conflictID {
            profile["id"] = .string(conflictID)
            profile["priority"] = .int(-10_000)
        }
        remove(.profile, id: conflictID ?? id, from: &document)
        document.profiles.append(profile)
    }
}
