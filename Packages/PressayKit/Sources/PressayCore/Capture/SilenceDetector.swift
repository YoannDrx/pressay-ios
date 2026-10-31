import Foundation

/// Decides when a dictation should stop by itself, from the level of the 16 kHz samples.
///
/// The signal is cut into 30 ms frames; a frame is speech when its RMS level exceeds the
/// threshold. Once speech has been heard, `silenceDuration` seconds without speech stop the
/// dictation. When nothing is heard for `noSpeechTimeout` seconds, the microphone stops too:
/// Pressay never keeps a microphone open for nothing.
public struct SilenceDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// RMS level above which a frame counts as speech (0.015 in the spike).
        public var threshold: Float
        /// Seconds of silence after speech that stop the dictation; nil disables the stop on silence.
        public var silenceDuration: TimeInterval?
        /// Seconds without any speech after which the dictation stops; nil disables it.
        public var noSpeechTimeout: TimeInterval?
        public var sampleRate: Double

        public init(
            threshold: Float = 0.015,
            silenceDuration: TimeInterval? = 1.5,
            noSpeechTimeout: TimeInterval? = 10,
            sampleRate: Double = TranscriptionAudio.sampleRate
        ) {
            self.threshold = threshold
            self.silenceDuration = silenceDuration
            self.noSpeechTimeout = noSpeechTimeout
            self.sampleRate = sampleRate
        }

        public static let `default` = Configuration()
    }

    public enum Verdict: String, Sendable, Equatable {
        /// Keep recording.
        case listening
        /// Speech was heard, then `silenceDuration` seconds of silence.
        case silenceAfterSpeech
        /// Nothing was heard for `noSpeechTimeout` seconds.
        case noSpeech
    }

    public let configuration: Configuration
    public private(set) var heardSpeech = false
    public private(set) var sampleCount = 0
    private var trailingSilence = 0
    private var pending: [Float] = []
    private let frameLength: Int

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        frameLength = max(1, Int(configuration.sampleRate * 0.03))
        pending.reserveCapacity(frameLength)
    }

    public var verdict: Verdict {
        if heardSpeech {
            if let duration = configuration.silenceDuration,
               trailingSilence >= Int(duration * configuration.sampleRate) {
                return .silenceAfterSpeech
            }
            return .listening
        }
        if let timeout = configuration.noSpeechTimeout, sampleCount >= Int(timeout * configuration.sampleRate) {
            return .noSpeech
        }
        return .listening
    }

    public mutating func consume(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { consume($0) }
    }

    public mutating func consume(_ samples: UnsafeBufferPointer<Float>) {
        sampleCount += samples.count
        for sample in samples {
            pending.append(sample)
            if pending.count == frameLength {
                classifyFrame()
            }
        }
    }

    private mutating func classifyFrame() {
        if Self.rms(pending) > configuration.threshold {
            heardSpeech = true
            trailingSilence = 0
        } else {
            trailingSilence += pending.count
        }
        pending.removeAll(keepingCapacity: true)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (energy / Float(samples.count)).squareRoot()
    }
}
