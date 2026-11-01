import Foundation
import Observation
import PressayAccount
import PressayShared

/// The dictionary and the active mode as the interface sees them. Edits go through the store, then
/// a sync run if this iPhone has joined one.
@MainActor
@Observable
final class ProductivityModel {
    static let shared = ProductivityModel()

    private(set) var document = ProductivityDocument()
    private(set) var trialsRemaining = ProLimits.freeAITrials
    private(set) var syncSnapshot: SyncSnapshot?
    private(set) var lastSync: SyncRunReport?
    private(set) var isSyncing = false

    @ObservationIgnored private let store = AccountEnvironment.productivity
    @ObservationIgnored private let sync = AccountEnvironment.sync
    @ObservationIgnored private var lastSyncRun: Date?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    private static let syncInterval: TimeInterval = 15 * 60

    private init() {}

    func load() async {
        document = await store.document()
        trialsRemaining = AccountEnvironment.trials.remaining
    }

    // MARK: Dictionary

    func canAddWord(isPro: Bool) -> Bool {
        ProLimits.canAddDictionaryEntry(count: document.dictionary.count, isPro: isPro)
    }

    func save(_ entry: DictionaryEntry) {
        change { document in
            if let index = document.dictionary.firstIndex(where: { $0.id == entry.id }) {
                document.dictionary[index] = entry
            } else {
                document.dictionary.append(entry)
            }
        }
    }

    func delete(_ entry: DictionaryEntry) {
        change { document in
            document.dictionary.removeAll { $0.id == entry.id }
        }
    }

    // MARK: Modes

    func selectMode(_ id: String) {
        change { $0.activeModeID = id }
    }

    private func change(_ body: @escaping @Sendable (inout ProductivityDocument) -> Void) {
        Task {
            do {
                try await store.modify(body)
                document = await store.document()
                scheduleSync()
            } catch {
                PressayLog.shared.event("productivity.writeFailed", ["error": ErrorTag.of(error)])
            }
        }
    }

    // MARK: Sync

    /// Waits a moment after an edit, so several edits make one run.
    private func scheduleSync() {
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await runSyncIfReady()
        }
    }

    func runSyncIfDue() async {
        if let lastSyncRun, Date().timeIntervalSince(lastSyncRun) < Self.syncInterval { return }
        await runSyncIfReady()
    }

    /// Only a Pro iPhone that already holds the key syncs: nothing is ever sent otherwise.
    private func runSyncIfReady() async {
        guard AccountModel.shared.isConnected, AccountModel.shared.isPro else { return }
        do {
            guard try await sync.snapshot().status == .ready else { return }
            try await runSync()
        } catch {
            PressayLog.shared.event("sync.failed", ["code": .tag((error as? CloudFailure)?.code ?? "unknown")])
        }
    }

    private func runSync() async throws {
        isSyncing = true
        defer { isSyncing = false }
        lastSyncRun = Date()
        lastSync = try await sync.run()
        document = await store.document()
    }

    func syncNow() async {
        do {
            try await runSync()
        } catch {
            AccountModel.shared.report(error)
        }
    }

    func loadSync() async {
        do {
            syncSnapshot = try await sync.snapshot()
        } catch {
            AccountModel.shared.report(error)
        }
    }

    func enableSync() async {
        do {
            syncSnapshot = try await sync.enable()
            if syncSnapshot?.status == .ready { await syncNow() }
        } catch {
            AccountModel.shared.report(error)
        }
    }

    func approve(_ device: SyncDevice) async {
        do {
            syncSnapshot = try await sync.approve(deviceID: device.id)
        } catch {
            AccountModel.shared.report(error)
        }
    }

    func recover(code: String) async {
        do {
            syncSnapshot = try await sync.recover(code: code)
            await syncNow()
        } catch {
            AccountModel.shared.report(error)
        }
    }

    func createRecoveryCode() async -> String? {
        do {
            return try await sync.createRecoveryCode()
        } catch {
            AccountModel.shared.report(error)
            return nil
        }
    }
}
