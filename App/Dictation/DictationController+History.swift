import Foundation
import PressayCore
import PressayShared
import Security

/// The encrypted local history (`DictationHistory`, keyed by `HistoryKey`).
extension DictationController {
    /// The encrypted history, once its Keychain key is readable (after the first unlock).
    var historyStore: DictationHistory? {
        if let resolvedHistoryStore { return resolvedHistoryStore }
        do {
            let store = DictationHistory.applicationSupport(key: try HistoryKey.loadOrCreate())
            try? store.encryptLegacyFile()
            resolvedHistoryStore = store
            return store
        } catch {
            PressayLog.shared.event("history.keyUnavailable", ["error": ErrorTag.of(error)])
            return nil
        }
    }

    /// Reads the history again if it could not be read at launch (Keychain still locked).
    func loadHistory() {
        guard resolvedHistoryStore == nil || history.isEmpty, let store = historyStore else { return }
        do {
            history = try store.entries()
        } catch {
            PressayLog.shared.event("history.readFailed", ["error": ErrorTag.of(error)])
        }
    }

    /// No engine can run until the Fast model is downloaded.
    var needsModelDownload: Bool {
        models.state != .installed && !AppleSpeechTranscriber.isAvailable
    }

    /// Pro keeps everything; Free keeps a wide margin and shows the last days.
    func addToHistory(_ entry: HistoryEntry, isPro: Bool) {
        do {
            guard let historyStore else { throw HistoryKey.Failure.unavailable(errSecInteractionNotAllowed) }
            try historyStore.add(entry, capacity: isPro ? nil : DictationHistory.freeCapacity)
        } catch {
            PressayLog.shared.event("history.writeFailed", ["error": ErrorTag.of(error)])
        }
        history.insert(entry, at: 0)
        history.sort { $0.createdAt > $1.createdAt }
    }

    func removeFromHistory(_ entry: HistoryEntry) {
        try? historyStore?.remove(id: entry.id)
        history.removeAll { $0.id == entry.id }
    }

    func clearHistory() {
        try? historyStore?.removeAll()
        history.removeAll()
    }
}
