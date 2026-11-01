#if PRESSAY_SYNC
import Foundation
import PressayAccount
import PressayShared
import PressaySync

/// Encrypted sync with the Mac. Left out of shipped builds: see "Encrypted sync" in the README.
extension ProductivityModel {
    private static let syncInterval: TimeInterval = 15 * 60

    /// Waits a moment after an edit, so several edits make one run.
    func scheduleSync() {
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
#endif
