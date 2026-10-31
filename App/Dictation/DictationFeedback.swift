import AudioToolbox
import UIKit

/// The sounds and taps that mark a dictation, as the user set them. Haptics only play while
/// the app is in front: iOS ignores them in the background, where the Live Activity and
/// the keyboard's bar show the state instead.
@MainActor
final class DictationFeedback {
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    /// System sounds "begin recording" and "end recording".
    private static let startSound: SystemSoundID = 1113
    private static let endSound: SystemSoundID = 1114

    func started(_ settings: DictationSettings) {
        if settings.haptics { impact.impactOccurred() }
        if settings.sounds { AudioServicesPlaySystemSound(Self.startSound) }
    }

    func delivered(_ settings: DictationSettings) {
        if settings.haptics { notification.notificationOccurred(.success) }
        if settings.sounds { AudioServicesPlaySystemSound(Self.endSound) }
    }

    func failed(_ settings: DictationSettings) {
        if settings.haptics { notification.notificationOccurred(.error) }
    }
}
