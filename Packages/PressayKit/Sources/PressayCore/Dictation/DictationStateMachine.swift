import Foundation
import PressayShared

/// Why a recording ended. Logged as a tag, shown to nobody.
public enum StopReason: String, Sendable, Equatable, CaseIterable {
    /// A second press of the Action button, the Control, Siri or the app's button.
    case toggle
    /// The Stop button of the Live Activity or of the keyboard.
    case stopButton
    /// Speech followed by the configured silence.
    case silence
    /// Nothing was heard.
    case noSpeech
    /// The safety cap on a single dictation.
    case maxDuration
    /// A call, Siri or another app took the audio session.
    case interruption
    /// The microphone went away (headset unplugged) and could not be restarted.
    case routeLost
}

public enum DictationEvent: Sendable, Equatable {
    /// Start when idle, stop when recording, ignored while transcribing.
    case toggle
    /// Stop a recording; ignored in any other phase.
    case stop(StopReason)
    /// The microphone could not start.
    case captureFailed
    /// The text reached the result queue.
    case delivered
    /// Transcription failed or produced nothing.
    case failed
}

public enum DictationCommand: Sendable, Equatable {
    case startCapture
    case stopCapture(StopReason)
}

/// The dictation lifecycle, free of any audio or UI so it can be tested off device.
///
/// idle / delivered / failed --toggle--> recording --toggle or stop--> transcribing
/// --delivered--> delivered, --failed--> failed. A toggle while transcribing is ignored:
/// the Action button needs a long press, and a stray one must not start a new recording
/// over the text being produced.
public struct DictationStateMachine: Sendable, Equatable {
    public private(set) var phase: DictationPhase

    public init(phase: DictationPhase = .idle) {
        self.phase = phase
    }

    /// Applies `event` and returns what the controller must do, or nil when nothing changes.
    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> DictationCommand? {
        switch (phase, event) {
        case (.idle, .toggle), (.delivered, .toggle), (.failed, .toggle):
            phase = .recording
            return .startCapture
        case (.recording, .toggle):
            phase = .transcribing
            return .stopCapture(.toggle)
        case let (.recording, .stop(reason)):
            phase = .transcribing
            return .stopCapture(reason)
        case (.recording, .captureFailed):
            phase = .failed
            return nil
        case (.transcribing, .delivered):
            phase = .delivered
            return nil
        case (.transcribing, .failed):
            phase = .failed
            return nil
        default:
            return nil
        }
    }
}
