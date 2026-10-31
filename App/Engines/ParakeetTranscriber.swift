import CoreML
import FluidAudio
import Foundation
import PressayCore
import PressayShared

/// The Fast engine: Parakeet TDT v3 through FluidAudio, from the files the model download
/// verified. Never on the GPU: iOS refuses Metal to a background app, and dictation from
/// the Action button always runs in the background. The Neural Engine is an acceleration
/// only (0.07 s per phrase against 0.14 s on CPU in spike S2): if it fails, the engine
/// reloads on the CPU alone and tries again.
actor ParakeetTranscriber: Transcriber {
    nonisolated let engine = EngineID.fast

    private let directory: URL
    private var manager: AsrManager?
    private var computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    init(directory: URL) {
        self.directory = directory
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let start = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let models = try AsrModels.loadLocal(
            from: directory,
            version: .v3,
            configuration: configuration,
            encoderComputeUnits: computeUnits
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        PressayLog.shared.event("engine.loaded", [
            "engine": .tag(engine.rawValue),
            "units": .tag(unitsTag),
            "seconds": .double(Date().timeIntervalSince(start)),
        ])
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> String {
        do {
            return try await run(samples, languageHint: languageHint)
        } catch where computeUnits != .cpuOnly {
            PressayLog.shared.event("engine.cpuFallback", [
                "engine": .tag(engine.rawValue), "error": ErrorTag.of(error),
            ])
            computeUnits = .cpuOnly
            manager = nil
            return try await run(samples, languageHint: languageHint)
        }
    }

    /// Frees the model's memory, for instance after the user deleted it.
    func unload() {
        manager = nil
    }

    private func run(_ samples: [Float], languageHint: String?) async throws -> String {
        try await prepare()
        guard let manager else { throw TranscriberError.notReady }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(
            samples,
            decoderState: &state,
            language: languageHint.flatMap(Language.init(rawValue:))
        )
        return result.text
    }

    private var unitsTag: String {
        computeUnits == .cpuOnly ? "cpuOnly" : "cpuAndNeuralEngine"
    }
}
