import Foundation
import PressayCore
import PressayShared

struct TranscriptionOutput {
    let text: String
    let engine: EngineID
    let seconds: Double
}

/// Picks the engine for each dictation and falls back when one cannot run: the preferred
/// engine first, then the other. Fast needs its model on disk; Apple needs a device
/// and language that `SpeechAnalyzer` supports.
@MainActor
final class EngineStore {
    private let modelStore: ModelStore
    private let fast: ParakeetTranscriber
    private let apple = AppleSpeechTranscriber()

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
        fast = ParakeetTranscriber(directory: modelStore.directory(for: .parakeetTDTv3))
    }

    var isFastInstalled: Bool {
        modelStore.isInstalled(.parakeetTDTv3)
    }

    func chain(preferring preferred: EngineID) -> [any Transcriber] {
        let fastEngine: [any Transcriber] = isFastInstalled ? [fast] : []
        let appleEngine: [any Transcriber] = AppleSpeechTranscriber.isAvailable ? [apple] : []
        return preferred == .apple ? appleEngine + fastEngine : fastEngine + appleEngine
    }

    /// Loads the engine while the user speaks: the first dictation of the spike waited
    /// 8.8 s for the model otherwise.
    func prepare(preferring preferred: EngineID) async {
        guard let engine = chain(preferring: preferred).first else { return }
        do {
            try await engine.prepare()
        } catch {
            PressayLog.shared.event("engine.prepareFailed", [
                "engine": .tag(engine.engine.rawValue), "error": ErrorTag.of(error),
            ])
        }
    }

    func transcribe(_ samples: [Float], preferring preferred: EngineID, language: String) async throws -> TranscriptionOutput {
        let engines = chain(preferring: preferred)
        guard !engines.isEmpty else { throw TranscriberError.noEngine }
        var lastError: Error = TranscriberError.noEngine
        for engine in engines {
            let start = Date()
            do {
                let text = try await engine.transcribe(samples: samples, languageHint: language)
                return TranscriptionOutput(text: text, engine: engine.engine, seconds: Date().timeIntervalSince(start))
            } catch {
                PressayLog.shared.event("engine.failed", [
                    "engine": .tag(engine.engine.rawValue), "error": ErrorTag.of(error),
                ])
                lastError = error
            }
        }
        throw lastError
    }

    func unloadFast() async {
        await fast.unload()
    }
}
