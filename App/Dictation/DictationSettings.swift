import Foundation
import Observation
import PressayCore

/// The user's dictation preferences, stored in the app's own defaults.
@MainActor
@Observable
final class DictationSettings {
    static let silenceDelays: [Double] = [1, 1.5, 2, 3]
    static let languages = ["fr", "en"]

    private enum Key {
        static let engine = "dictation.engine"
        static let stopOnSilence = "dictation.stopOnSilence"
        static let silenceDelay = "dictation.silenceDelay"
        static let silenceThreshold = "dictation.silenceThreshold"
        static let language = "dictation.language"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Fast by default (decision after spike S2); Apple when the user prefers nothing to download.
    var engine: EngineID {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    /// On by default: it saves the second long press of the Action button.
    var stopOnSilence: Bool {
        didSet { defaults.set(stopOnSilence, forKey: Key.stopOnSilence) }
    }

    var silenceDelay: Double {
        didSet { defaults.set(silenceDelay, forKey: Key.silenceDelay) }
    }

    /// RMS level under which a frame is silence. Not in the interface yet: 0.015 held on
    /// the spike's 43 real dictations.
    var silenceThreshold: Float {
        didSet { defaults.set(silenceThreshold, forKey: Key.silenceThreshold) }
    }

    /// "fr" or "en": the locale of the Apple engine and a script hint for Parakeet.
    var language: String {
        didSet { defaults.set(language, forKey: Key.language) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = defaults.string(forKey: Key.engine).flatMap(EngineID.init(rawValue:)) ?? .fast
        stopOnSilence = defaults.object(forKey: Key.stopOnSilence) as? Bool ?? true
        silenceDelay = defaults.object(forKey: Key.silenceDelay) as? Double ?? 1.5
        silenceThreshold = defaults.object(forKey: Key.silenceThreshold) as? Float ?? 0.015
        let preferred = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "fr"
        language = defaults.string(forKey: Key.language) ?? (preferred == "en" ? "en" : "fr")
    }

    var silenceConfiguration: SilenceDetector.Configuration {
        SilenceDetector.Configuration(
            threshold: silenceThreshold,
            silenceDuration: stopOnSilence ? silenceDelay : nil,
            noSpeechTimeout: 10
        )
    }
}
