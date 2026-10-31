import AVFoundation
import Foundation
import Observation
import PressayCore
import PressayShared

/// What started a dictation. Logged as a tag.
enum TriggerSource: String {
    /// The Action button, Control Center, the Lock Screen, Siri or Shortcuts.
    case intent
    /// The Dictate button of the app.
    case app
    /// The keyboard's microphone button (lot I3).
    case keyboard
}

/// Why a dictation produced no text. Shown in the app, never containing user content.
enum DictationFailure: String, Equatable {
    case microphoneDenied
    case microphoneUnavailable
    case storageUnavailable
    case noSpeech
    case tooShort
    case nothingRecognized
    case noEngine
    case transcriptionFailed

    var message: LocalizedStringResource {
        switch self {
        case .microphoneDenied: "failure.microphoneDenied"
        case .microphoneUnavailable: "failure.microphoneUnavailable"
        case .storageUnavailable: "failure.storageUnavailable"
        case .noSpeech: "failure.noSpeech"
        case .tooShort: "failure.tooShort"
        case .nothingRecognized: "failure.nothingRecognized"
        case .noEngine: "failure.noEngine"
        case .transcriptionFailed: "failure.transcriptionFailed"
        }
    }
}

/// Runs a dictation from any trigger: microphone, capture file, engine, then the result
/// queue the Pressay keyboard reads, and the history. Keeps `SessionStore` up to date so
/// the keyboard and the widgets follow along.
@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    /// A safety cap: Pressay never keeps the microphone open without end.
    static let maximumDuration: TimeInterval = 300
    /// Shorter captures are a slip of the finger, not a dictation.
    static let minimumDuration: TimeInterval = 0.3
    /// Orphaned captures older than this are deleted rather than transcribed.
    static let orphanMaximumAge: TimeInterval = 24 * 3600

    private(set) var phase: DictationPhase = .idle
    private(set) var failure: DictationFailure?
    private(set) var recordingStartedAt: Date?
    private(set) var history: [HistoryEntry] = []

    let settings = DictationSettings()
    let models: ModelLibrary

    @ObservationIgnored private var machine = DictationStateMachine()
    @ObservationIgnored private let capture = AudioCaptureService()
    @ObservationIgnored let engines: EngineStore
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let background = BackgroundActivity(name: "transcription")
    @ObservationIgnored let captures = CaptureStore.shared
    @ObservationIgnored private let historyStore = DictationHistory.applicationSupport
    @ObservationIgnored private let session = SessionStore.shared
    @ObservationIgnored private var writer: CaptureWriter?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?

    private init() {
        let modelStore = ModelStore.applicationSupport
        models = ModelLibrary(store: modelStore)
        engines = EngineStore(modelStore: modelStore)
        history = (try? historyStore.entries()) ?? []
        models.onRemoved = { [engines] in
            Task { await engines.unloadFast() }
        }
        capture.onInterruption = { [weak self] interruption in
            Task { await self?.stop(reason: interruption == .interrupted ? .interruption : .routeLost) }
        }
        DarwinNotifier.observe(PressaySignal.keyboardRequestsToggle) {
            Task { @MainActor in await DictationController.shared.keyboardRequestedToggle() }
        }
        // Listed before any new capture can start: every file present now is an orphan.
        let orphans = captures?.captures() ?? []
        // A previous process died during a dictation: the keyboard must not wait for it.
        if let session, session.phase == .recording || session.phase == .transcribing {
            session.setPhase(.failed)
        }
        if !orphans.isEmpty {
            Task { await recover(orphans) }
        }
    }

    var lastEntry: HistoryEntry? { history.first }

    /// No engine can run until the Fast model is downloaded.
    var needsModelDownload: Bool {
        models.state != .installed && !AppleSpeechTranscriber.isAvailable
    }

    // MARK: Triggers

    func toggle(source: TriggerSource) async {
        PressayLog.shared.event("dictation.toggle", [
            "source": .tag(source.rawValue),
            "phase": .tag(machine.phase.rawValue),
            "appState": .tag(BackgroundActivity.applicationStateTag),
        ])
        await apply(machine.handle(.toggle), source: source)
    }

    func stop(reason: StopReason) async {
        await apply(machine.handle(.stop(reason)), source: .app)
    }

    /// Runs the work in its own task: the caller (the silence watcher, an intent the system
    /// may cancel) must never cancel a transcription half-way. Callers still wait for it,
    /// so an intent returns once the text is delivered.
    private func apply(_ command: DictationCommand?, source: TriggerSource) async {
        let work: Task<Void, Never>
        switch command {
        case .startCapture: work = Task { await startCapture(source: source) }
        case let .stopCapture(reason): work = Task { await finishCapture(reason: reason) }
        case nil: return
        }
        await work.value
    }

    // MARK: Capture

    private func startCapture(source: TriggerSource) async {
        let requestedAt = Date()
        failure = nil
        recordingStartedAt = requestedAt
        setPhase(.recording)

        let fileSource = Self.debugFileSource
        if fileSource == nil {
            guard await AVAudioApplication.requestRecordPermission() else {
                return captureFailed(.microphoneDenied)
            }
        } else {
            // The microphone's audio session keeps the app running in the background; a file
            // has none, so the simulator would suspend the app mid-capture without this.
            background.begin()
        }
        // Stopped while the permission prompt was up.
        guard machine.phase == .recording else { return }
        guard let captures, let writer = try? captures.makeWriter(id: UUID()) else {
            return captureFailed(.storageUnavailable)
        }
        do {
            try capture.start(
                writer: writer,
                silence: settings.silenceConfiguration,
                source: fileSource.map(CaptureSource.file) ?? .microphone
            )
        } catch {
            writer.close()
            captures.remove(id: writer.id)
            capture.shutdown()
            PressayLog.shared.event("capture.failed", ["error": ErrorTag.of(error)])
            return captureFailed(.microphoneUnavailable)
        }
        self.writer = writer
        let liveActivity = liveActivity.start(startedAt: requestedAt)
        startWatching()
        let preferred = settings.engine
        prewarmTask = Task { [engines] in await engines.prepare(preferring: preferred) }
        PressayLog.shared.event("capture.started", [
            "source": .tag(source.rawValue),
            "appState": .tag(BackgroundActivity.applicationStateTag),
            "startLatencyMs": .int(Int(Date().timeIntervalSince(requestedAt) * 1000)),
            "liveActivity": .bool(liveActivity),
            "input": .tag(fileSource == nil ? AudioCaptureService.currentInputTag : "file"),
        ])
    }

    private func captureFailed(_ reason: DictationFailure) {
        machine.handle(.captureFailed)
        failure = reason
        setPhase(.failed)
        liveActivity.end(.failed)
        PressayLog.shared.event("capture.refused", ["reason": .tag(reason.rawValue)])
    }

    /// Stops on silence, on prolonged silence before any speech, and at the duration cap.
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.machine.phase == .recording else { return }
                let reason: StopReason? = switch self.capture.verdict {
                case .silenceAfterSpeech: .silence
                case .noSpeech: .noSpeech
                case .listening: self.capture.capturedSeconds >= Self.maximumDuration ? .maxDuration : nil
                }
                if let reason {
                    await self.stop(reason: reason)
                    return
                }
            }
        }
    }

    // MARK: Transcription and delivery

    private func finishCapture(reason: StopReason) async {
        watchTask?.cancel()
        watchTask = nil
        // Keep running until the text is delivered, even if the user leaves the app.
        background.begin()
        defer {
            capture.shutdown()
            background.end()
        }
        setPhase(.transcribing)
        liveActivity.update(.transcribing)

        let summary = capture.finish()
        let writer = writer
        self.writer = nil
        PressayLog.shared.event("capture.stopped", [
            "reason": .tag(reason.rawValue),
            "audioSeconds": .double(summary?.seconds ?? 0),
            "heardSpeech": .bool(summary?.heardSpeech ?? false),
            "appState": .tag(BackgroundActivity.applicationStateTag),
        ])
        guard let writer, let summary, let captures else { return transcriptionFailed(.tooShort, captureID: nil) }
        if reason == .noSpeech {
            return transcriptionFailed(.noSpeech, captureID: writer.id)
        }
        guard summary.seconds >= Self.minimumDuration else {
            return transcriptionFailed(.tooShort, captureID: writer.id)
        }

        await transcribeAndDeliver(captureID: writer.id, audioSeconds: summary.seconds, from: captures)
    }

    private func transcribeAndDeliver(captureID: UUID, audioSeconds: Double, from captures: CaptureStore) async {
        do {
            let samples = try captures.readSamples(id: captureID)
            await prewarmTask?.value
            let output = try await engines.transcribe(samples, preferring: settings.engine, language: settings.language)
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return transcriptionFailed(.nothingRecognized, captureID: captureID)
            }
            let entry = HistoryEntry(
                text: text,
                engine: output.engine,
                audioSeconds: audioSeconds,
                transcriptionSeconds: output.seconds
            )
            addToHistory(entry)
            try publish(entry)
            captures.remove(id: captureID)
            machine.handle(.delivered)
            setPhase(.delivered)
            liveActivity.end(.delivered)
            PressayLog.shared.event("transcription.done", [
                "engine": .tag(output.engine.rawValue),
                "audioSeconds": .double(audioSeconds),
                "inferenceSeconds": .double(output.seconds),
                "characters": .int(text.count),
                "appState": .tag(BackgroundActivity.applicationStateTag),
            ])
        } catch let error as TranscriberError where error == .noEngine {
            // Kept on disk: it is transcribed at the next launch once an engine is available.
            transcriptionFailed(.noEngine, captureID: nil)
        } catch is ResultQueueUnavailable {
            transcriptionFailed(.storageUnavailable, captureID: captureID)
        } catch {
            PressayLog.shared.event("transcription.failed", ["error": ErrorTag.of(error)])
            // Kept on disk: the next launch retries it once.
            transcriptionFailed(.transcriptionFailed, captureID: nil)
        }
    }

    private func transcriptionFailed(_ reason: DictationFailure, captureID: UUID?) {
        if let captureID {
            captures?.remove(id: captureID)
        }
        machine.handle(.failed)
        failure = reason
        setPhase(.failed)
        liveActivity.end(.failed)
        PressayLog.shared.event("dictation.failed", ["reason": .tag(reason.rawValue)])
    }

    /// Hands the text to the Pressay keyboard through the App Group.
    private func publish(_ entry: HistoryEntry) throws {
        guard let queue = ResultQueue.shared else { throw ResultQueueUnavailable() }
        try queue.enqueue(entry.result)
        DarwinNotifier.post(PressaySignal.resultReady)
    }

    func addToHistory(_ entry: HistoryEntry) {
        do {
            try historyStore.add(entry)
        } catch {
            PressayLog.shared.event("history.writeFailed", ["error": ErrorTag.of(error)])
        }
        history.insert(entry, at: 0)
        history.sort { $0.createdAt > $1.createdAt }
    }

    func removeFromHistory(_ entry: HistoryEntry) {
        try? historyStore.remove(id: entry.id)
        history.removeAll { $0.id == entry.id }
    }

    func clearHistory() {
        try? historyStore.removeAll()
        history.removeAll()
    }

    private func setPhase(_ newPhase: DictationPhase) {
        phase = newPhase
        session?.setPhase(newPhase)
    }

    // MARK: Debug

    /// `-PressayCaptureFile /path/to.wav` replaces the microphone by a file in debug builds,
    /// so a full dictation runs in the simulator.
    private static var debugFileSource: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "PressayCaptureFile").map { URL(fileURLWithPath: $0) }
        #else
        nil
        #endif
    }
}

extension DictationController {
    /// The keyboard's microphone button. iOS delivers the signal to a suspended app only when
    /// it resumes it, maybe much later: a request older than a couple of seconds is dropped
    /// rather than starting a dictation nobody is waiting for.
    private func keyboardRequestedToggle() async {
        let fresh = session?.takeToggleRequest() ?? false
        PressayLog.shared.event("keyboard.toggle.received", [
            "fresh": .bool(fresh),
            "phase": .tag(machine.phase.rawValue),
            "appState": .tag(BackgroundActivity.applicationStateTag),
        ])
        guard fresh else { return }
        await toggle(source: .keyboard)
    }
}

struct ResultQueueUnavailable: Error {}
