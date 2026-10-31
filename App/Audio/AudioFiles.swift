import AVFoundation
import PressayCore

enum AudioFileError: Error {
    case unsupportedFormat
    case allocationFailed
}

/// Conversions between files and the 16 kHz mono Float32 samples every engine receives.
enum AudioFiles {
    static var format: AVAudioFormat {
        // Float32 mono at a standard rate is always a valid format.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: TranscriptionAudio.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Writes samples to a temporary WAV file, for engines that only read files.
    static func writeTemporaryWAV(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw AudioFileError.allocationFailed }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Reads any audio file and converts it to 16 kHz mono Float32.
    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw AudioFileError.unsupportedFormat
        }
        let ratio = TranscriptionAudio.sampleRate / file.processingFormat.sampleRate
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let output = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * ratio) + 1024
              )
        else { throw AudioFileError.allocationFailed }
        try file.read(into: input)
        let feed = ConverterFeed(input, then: .endOfStream)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { throw AudioFileError.allocationFailed }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Hands one buffer to `AVAudioConverter.convert(to:error:withInputFrom:)`, then reports
/// `exhausted`. The converter calls its input block synchronously, inside `convert`.
final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let exhausted: AVAudioConverterInputStatus

    init(_ buffer: AVAudioPCMBuffer, then exhausted: AVAudioConverterInputStatus) {
        self.buffer = buffer
        self.exhausted = exhausted
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = exhausted
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
