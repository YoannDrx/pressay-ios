import Foundation
import PressayAccount
import PressayShared

/// The last step of a dictation: the personal dictionary, then the active mode. Reads only what is
/// on the iPhone and sends nothing: a dictation never touches the network.
extension DictationController {
    struct FinishedText {
        let text: String
        /// The dictation before a mode rewrote it.
        let original: String?
        let modeID: String?
        let isPro: Bool
    }

    func finishText(_ transcribed: String) async -> FinishedText {
        let document = await AccountEnvironment.productivity.document()
        // Read each time, so rights that expired a moment ago no longer count.
        let isPro = await AccountEnvironment.account.cachedSnapshot().isPro
        let corrected = DictionaryApplier.apply(document.dictionary, to: transcribed)
        let mode = document.activeMode
        let start = Date()
        let runner = ModeRunner(trials: AccountEnvironment.trials, rewriter: Rewriters.current)
        let outcome = await runner.run(mode, on: corrected, dictionaryTerms: document.dictionaryTerms, isPro: isPro)
        lastModeFallback = outcome.fallback
        if mode.instruction != nil {
            PressayLog.shared.event("mode.done", [
                // The name of a custom mode is the user's: only built-in identifiers are logged.
                "mode": .tag(mode.isBuiltin ? mode.id : "custom"),
                "applied": .bool(outcome.appliedModeID != nil),
                "fallback": .tag(outcome.fallback?.rawValue ?? "none"),
                "milliseconds": .int(Int(Date().timeIntervalSince(start) * 1000)),
                "characters": .int(outcome.text.count),
            ])
            await ProductivityModel.shared.load()
        }
        return FinishedText(
            text: outcome.text,
            original: outcome.appliedModeID == nil ? nil : corrected,
            modeID: outcome.appliedModeID,
            isPro: isPro
        )
    }
}
