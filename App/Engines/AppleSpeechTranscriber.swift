import AVFoundation
import Foundation
import PressayCore
import Speech

/// The Apple engine: `SpeechAnalyzer`, on device, nothing to download from Pressay.
/// Less accurate in French than Parakeet (15 to 20 % of words wrong in spike S2), so it
/// serves until the Fast model is downloaded, and if the Fast engine fails.
actor AppleSpeechTranscriber: Transcriber {
    nonisolated let engine = EngineID.apple

    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    func prepare() async throws {
        for code in ["fr-FR", "en-US"] {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code)) else { continue }
            try await installAssets(for: SpeechTranscriber(locale: locale, preset: .transcription))
        }
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> String {
        let requested = Locale(identifier: languageHint == "en" ? "en-US" : "fr-FR")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLanguage
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installAssets(for: module)

        let url = try AudioFiles.writeTemporaryWAV(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        // The analyzer must stay alive until the end of the file is finalised: a discarded
        // analyzer stops before producing any result (spike S2).
        let collector = Task {
            var text = ""
            for try await result in module.results {
                text += String(result.text.characters)
            }
            return text
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installAssets(for module: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }
}
