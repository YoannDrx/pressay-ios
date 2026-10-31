import AVFoundation
import PressayCore
import PressayShared

enum CaptureSource: Equatable {
    case microphone
    /// Debug builds only: plays a file through the same pipeline, then silence, so the
    /// whole flow runs in the simulator without speaking.
    case file(URL)
}

/// Records the microphone at 16 kHz mono into a capture file in the App Group.
///
/// The audio session uses the spike's configuration, the one proven to start from the
/// Action button with the app in the background. Interruptions (a call, Siri) and a lost
/// microphone end the recording: what was captured is transcribed rather than lost.
@MainActor
final class AudioCaptureService {
    enum Interruption {
        /// Another app or a call took the audio session.
        case interrupted
        /// The input route changed and the engine could not be restarted on the new one.
        case routeLost
    }

    var onInterruption: ((Interruption) -> Void)?

    private let engine = AVAudioEngine()
    private var sink: CaptureSink?
    private var observers: [NSObjectProtocol] = []
    private var fileTask: Task<Void, Never>?
    private var sessionActive = false
    private var tapInstalled = false

    var verdict: SilenceDetector.Verdict { sink?.verdict ?? .listening }
    var capturedSeconds: Double { sink?.seconds ?? 0 }

    func start(writer: CaptureWriter, silence: SilenceDetector.Configuration, source: CaptureSource) throws {
        let sink = CaptureSink(writer: writer, silence: silence)
        switch source {
        case .microphone:
            try activateSession()
            try installTap(feeding: sink)
            engine.prepare()
            try engine.start()
            observeSession()
        case let .file(url):
            fileTask = Self.play(url, into: sink)
        }
        self.sink = sink
    }

    /// Ends the capture and closes its file. The engine keeps running until `shutdown()`:
    /// releasing the audio session now would let iOS suspend the app mid-transcription.
    func finish() -> CaptureSink.Summary? {
        fileTask?.cancel()
        fileTask = nil
        defer { sink = nil }
        return sink?.finish()
    }

    /// Stops the microphone and releases the audio session.
    func shutdown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    nonisolated static var currentInputTag: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none"
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)
        sessionActive = true
    }

    private func installTap(feeding sink: CaptureSink) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFileError.unsupportedFormat }
        sink.setInputFormat(format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }
        tapInstalled = true
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                PressayLog.shared.event("audio.interruption", ["began": .bool(began)])
                guard began else { return }
                MainActor.assumeIsolated { self?.onInterruption?(.interrupted) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                PressayLog.shared.event("audio.routeChange", [
                    "reason": .int(Int(reason)), "input": .tag(Self.currentInputTag),
                ])
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                PressayLog.shared.event("audio.mediaServicesReset")
                MainActor.assumeIsolated { self?.onInterruption?(.interrupted) }
            },
            // The engine stops itself when the input changes (AirPods out, wired headset in).
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
            },
        ]
    }

    private func restartAfterConfigurationChange() {
        guard let sink else { return }
        do {
            try installTap(feeding: sink)
            engine.prepare()
            try engine.start()
            PressayLog.shared.event("audio.engineRestarted", ["input": .tag(Self.currentInputTag)])
        } catch {
            PressayLog.shared.event("audio.engineRestartFailed", ["error": ErrorTag.of(error)])
            onInterruption?(.routeLost)
        }
    }

    /// Feeds a file at real-time pace in 100 ms chunks, then silence until `finish()`.
    private static func play(_ url: URL, into sink: CaptureSink) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let samples = (try? AudioFiles.readSamples(url)) ?? []
            PressayLog.shared.event("capture.fileSource", ["seconds": .double(Double(samples.count) / 16_000)])
            let chunk = Int(TranscriptionAudio.sampleRate / 10)
            let silence = [Float](repeating: 0, count: chunk)
            var index = 0
            while !Task.isCancelled {
                let slice = index < samples.count ? Array(samples[index..<min(index + chunk, samples.count)]) : silence
                slice.withUnsafeBufferPointer { sink.consume($0) }
                index += chunk
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
