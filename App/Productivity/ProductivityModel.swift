import Foundation
import Observation
import PressayAccount
import PressayShared
#if PRESSAY_SYNC
import PressaySync
#endif

/// The dictionary and the active mode as the interface sees them. Edits go through the store.
@MainActor
@Observable
final class ProductivityModel {
    static let shared = ProductivityModel()

    var document = ProductivityDocument()
    private(set) var trialsRemaining = ProLimits.freeAITrials
    #if PRESSAY_SYNC
    var syncSnapshot: SyncSnapshot?
    var lastSync: SyncRunReport?
    var isSyncing = false
    @ObservationIgnored let sync = AccountEnvironment.sync
    @ObservationIgnored var lastSyncRun: Date?
    @ObservationIgnored var pendingSync: Task<Void, Never>?
    #endif

    @ObservationIgnored let store = AccountEnvironment.productivity

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
                #if PRESSAY_SYNC
                scheduleSync()
                #endif
            } catch {
                PressayLog.shared.event("productivity.writeFailed", ["error": ErrorTag.of(error)])
            }
        }
    }
}
