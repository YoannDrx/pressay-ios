import Foundation
import PressayCore
import PressayShared

extension DictationController {
    /// Transcribes captures a killed process left behind. They go to the history only: an
    /// old dictation must not land in whatever field the keyboard shows now.
    func recover(_ orphans: [CaptureFile]) async {
        guard let captures else { return }
        for orphan in orphans {
            let age = Date().timeIntervalSince(orphan.createdAt)
            guard orphan.seconds >= Self.minimumDuration, age <= Self.orphanMaximumAge else {
                captures.remove(id: orphan.id)
                continue
            }
            do {
                let samples = try captures.readSamples(id: orphan.id)
                let output = try await engines.transcribe(samples, preferring: settings.engine, language: settings.language)
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    addToHistory(HistoryEntry(
                        text: text,
                        engine: output.engine,
                        createdAt: orphan.createdAt,
                        audioSeconds: orphan.seconds,
                        transcriptionSeconds: output.seconds,
                        recovered: true
                    ))
                }
                captures.remove(id: orphan.id)
                PressayLog.shared.event("recovery.done", [
                    "audioSeconds": .double(orphan.seconds), "characters": .int(text.count),
                ])
            } catch let error as TranscriberError where error == .noEngine {
                // Retried at a later launch, once the model is downloaded.
                PressayLog.shared.event("recovery.deferred")
            } catch {
                captures.remove(id: orphan.id)
                PressayLog.shared.event("recovery.failed", ["error": ErrorTag.of(error)])
            }
        }
    }
}
