import AVFoundation
import PressayCore

/// Receives microphone buffers on the audio thread, converts them to 16 kHz mono, writes
/// them to the capture file as they arrive and feeds the silence detector.
final class CaptureSink: @unchecked Sendable {
    struct Summary {
        let sampleCount: Int
        let heardSpeech: Bool

        var seconds: Double { Double(sampleCount) / TranscriptionAudio.sampleRate }
    }

    private let lock = NSLock()
    private let writer: CaptureWriter
    private var detector: SilenceDetector
    private var converter: AVAudioConverter?
    private var isCapturing = true
    private(set) var writeFailed = false

    init(writer: CaptureWriter, silence: SilenceDetector.Configuration) {
        self.writer = writer
        detector = SilenceDetector(configuration: silence)
    }

    var verdict: SilenceDetector.Verdict {
        lock.withLock { detector.verdict }
    }

    var seconds: Double {
        lock.withLock { Double(detector.sampleCount) / TranscriptionAudio.sampleRate }
    }

    /// Called again when the route changes: a headset can bring another sample rate.
    func setInputFormat(_ inputFormat: AVAudioFormat) {
        let converter = AVAudioConverter(from: inputFormat, to: AudioFiles.format)
        lock.withLock { self.converter = converter }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = lock.withLock({ isCapturing ? self.converter : nil }) else { return }
        let ratio = TranscriptionAudio.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioFiles.format, frameCapacity: capacity) else { return }
        // `.noDataNow`, not end of stream: the converter keeps its resampling state
        // between microphone buffers.
        let feed = ConverterFeed(buffer, then: .noDataNow)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }
        consume(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock {
            guard isCapturing else { return }
            do {
                try writer.append(samples)
            } catch {
                writeFailed = true
            }
            detector.consume(samples)
        }
    }

    /// Stops accepting samples and closes the file. The audio engine may keep running.
    func finish() -> Summary {
        lock.withLock {
            isCapturing = false
            writer.close()
            return Summary(sampleCount: writer.sampleCount, heardSpeech: detector.heardSpeech)
        }
    }
}
