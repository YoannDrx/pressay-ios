import Foundation

/// The engines Pressay offers on iPhone. Names match the Mac presets so both apps
/// tell the same story.
public enum EngineID: String, Codable, Sendable, CaseIterable {
    /// Parakeet TDT v3 through FluidAudio: the default, chosen after spike S2
    /// (12 % word error rate in French, 0.14 s per phrase on CPU only).
    case fast
    /// Apple's `SpeechAnalyzer`: nothing to download, less accurate in French.
    case apple
    /// Whisper Large v3 Turbo through WhisperKit: 99 languages.
    case polyglot
}

/// Audio every engine receives: mono, 16 kHz, 32-bit float samples in -1...1.
public enum TranscriptionAudio {
    public static let sampleRate: Double = 16_000
}

public enum TranscriberError: Error, Equatable, Sendable {
    /// The engine's model is not loaded.
    case notReady
    /// No engine can run: the Fast model is not downloaded and Apple's is unavailable.
    case noEngine
    /// The engine does not support the requested language on this device.
    case unsupportedLanguage
}

/// A local speech-to-text engine. The app implements it with FluidAudio and `SpeechAnalyzer`.
/// Engines must run on CPU or Neural Engine only: iOS refuses Metal in the background.
public protocol Transcriber: AnyObject, Sendable {
    var engine: EngineID { get }

    /// Downloads and loads the model if needed. Safe to call more than once.
    func prepare() async throws

    /// Transcribes `samples` at `TranscriptionAudio.sampleRate`.
    func transcribe(samples: [Float], languageHint: String?) async throws -> String
}
