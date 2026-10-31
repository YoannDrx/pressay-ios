import Testing
@testable import PressayCore

@Suite struct SilenceDetectorTests {
    let rate = TranscriptionAudio.sampleRate

    func samples(seconds: Double, level: Float) -> [Float] {
        // A square wave: its RMS level equals `level`.
        (0..<Int(seconds * rate)).map { $0.isMultiple(of: 2) ? level : -level }
    }

    @Test func stopsAfterSpeechThenSilence() {
        var detector = SilenceDetector(configuration: .init(silenceDuration: 1.5))
        detector.consume(samples(seconds: 1, level: 0.1))
        #expect(detector.heardSpeech)
        detector.consume(samples(seconds: 1.4, level: 0.001))
        #expect(detector.verdict == .listening)
        detector.consume(samples(seconds: 0.2, level: 0.001))
        #expect(detector.verdict == .silenceAfterSpeech)
    }

    @Test func speechResetsTheSilenceCount() {
        var detector = SilenceDetector(configuration: .init(silenceDuration: 1.5))
        detector.consume(samples(seconds: 0.5, level: 0.1))
        detector.consume(samples(seconds: 1.2, level: 0))
        detector.consume(samples(seconds: 0.3, level: 0.1))
        detector.consume(samples(seconds: 1.2, level: 0))
        #expect(detector.verdict == .listening)
    }

    @Test func silenceBeforeSpeechDoesNotStop() {
        var detector = SilenceDetector(configuration: .init(silenceDuration: 1.5, noSpeechTimeout: 10))
        detector.consume(samples(seconds: 5, level: 0.005))
        #expect(!detector.heardSpeech)
        #expect(detector.verdict == .listening)
    }

    @Test func stopsWhenNothingIsHeard() {
        var detector = SilenceDetector(configuration: .init(noSpeechTimeout: 3))
        detector.consume(samples(seconds: 3.1, level: 0.005))
        #expect(detector.verdict == .noSpeech)
    }

    @Test func stopOnSilenceCanBeDisabled() {
        var detector = SilenceDetector(configuration: .init(silenceDuration: nil))
        detector.consume(samples(seconds: 1, level: 0.1))
        detector.consume(samples(seconds: 10, level: 0))
        #expect(detector.verdict == .listening)
    }

    @Test func thresholdIsConfigurable() {
        var detector = SilenceDetector(configuration: .init(threshold: 0.05))
        detector.consume(samples(seconds: 1, level: 0.03))
        #expect(!detector.heardSpeech)
        detector.consume(samples(seconds: 0.1, level: 0.06))
        #expect(detector.heardSpeech)
    }

    @Test func chunkSizeDoesNotChangeTheVerdict() {
        var whole = SilenceDetector()
        var chunked = SilenceDetector()
        let signal = samples(seconds: 0.7, level: 0.1) + samples(seconds: 1.6, level: 0)
        whole.consume(signal)
        for start in stride(from: 0, to: signal.count, by: 1365) {
            chunked.consume(Array(signal[start..<min(start + 1365, signal.count)]))
        }
        #expect(whole.verdict == .silenceAfterSpeech)
        #expect(chunked.verdict == whole.verdict)
    }

    @Test func rmsOfASquareWaveIsItsAmplitude() {
        #expect(abs(SilenceDetector.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
        #expect(SilenceDetector.rms([]) == 0)
    }
}
