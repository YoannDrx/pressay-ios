import ActivityKit
import Foundation
import PressayShared

/// The Live Activity shown for the whole dictation. `AudioRecordingIntent` requires one:
/// without it the system stops the recording. It never shows the dictated text, which
/// would be readable on the Lock Screen, only the phase and the elapsed time.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: DictationPhase
        var startedAt: Date
    }
}
