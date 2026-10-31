import AppIntents
import Foundation

/// Starts or stops a dictation without opening the app: the Action button, Control Center,
/// the Lock Screen, Siri and Shortcuts all run it.
///
/// Compiled into the app and the widget extension. Both conformances are required: as an
/// `AudioRecordingIntent` alone, iOS 26 ran it in the widget extension, where nothing can
/// record (spike S1); `LiveActivityIntent` makes the system run it in the app's process.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "intent.toggle.title"
    static let description = IntentDescription("intent.toggle.description")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if PRESSAY_APP
        await DictationController.shared.toggle(source: .intent)
        #endif
        return .result()
    }
}

/// The Stop button of the Live Activity and the Dynamic Island. Unlike the toggle, a late
/// tap after the dictation already stopped on silence never starts a new one.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "intent.stop.title"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if PRESSAY_APP
        await DictationController.shared.stop(reason: .stopButton)
        #endif
        return .result()
    }
}
