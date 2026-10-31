import PressayCore
import SwiftUI

/// The words and symbol of each step. Keys live in `Translations/ios-strings.json`.
extension SetupStep {
    var title: LocalizedStringResource {
        switch self {
        case .microphone: "setup.microphone.title"
        case .keyboard: "setup.keyboard.title"
        case .fullAccess: "setup.fullAccess.title"
        case .trigger: "setup.trigger.title"
        case .firstDictation: "setup.firstDictation.title"
        }
    }

    func symbol(actionButton: Bool) -> String {
        switch self {
        case .microphone: "mic.fill"
        case .keyboard: "keyboard"
        case .fullAccess: "lock.open.fill"
        case .trigger: actionButton ? "button.horizontal.top.press.fill" : "switch.2"
        case .firstDictation: "text.bubble.fill"
        }
    }

    /// The steps that show a field where the Pressay keyboard can appear.
    var practicePrompt: LocalizedStringKey? {
        switch self {
        case .fullAccess: "setup.fullAccess.field"
        case .firstDictation: "setup.firstDictation.field"
        default: nil
        }
    }

    func summary(actionButton: Bool) -> LocalizedStringResource {
        switch self {
        case .microphone: "setup.microphone.summary"
        case .keyboard: "setup.keyboard.summary"
        case .fullAccess: "setup.fullAccess.summary"
        case .trigger: actionButton ? "setup.trigger.actionButton.summary" : "setup.trigger.controlCenter.summary"
        case .firstDictation: "setup.firstDictation.summary"
        }
    }

    func instructions(actionButton: Bool) -> [LocalizedStringResource] {
        switch self {
        case .microphone:
            ["setup.microphone.step1", "setup.microphone.step2"]
        case .keyboard:
            ["setup.keyboard.step1", "setup.keyboard.step2", "setup.keyboard.step3", "setup.keyboard.step4"]
        case .fullAccess:
            ["setup.fullAccess.step1", "setup.fullAccess.step2", "setup.fullAccess.step3"]
        case .trigger where actionButton:
            [
                "setup.trigger.actionButton.step1", "setup.trigger.actionButton.step2",
                "setup.trigger.actionButton.step3", "setup.trigger.actionButton.step4",
            ]
        case .trigger:
            [
                "setup.trigger.controlCenter.step1", "setup.trigger.controlCenter.step2",
                "setup.trigger.controlCenter.step3", "setup.trigger.controlCenter.step4",
            ]
        case .firstDictation:
            [
                "setup.firstDictation.step1", "setup.firstDictation.step2",
                "setup.firstDictation.step3", "setup.firstDictation.step4",
            ]
        }
    }

    /// The "Why?" bubble: what the step is for, and what Pressay does not do with it.
    var why: LocalizedStringResource {
        switch self {
        case .microphone: "setup.microphone.why"
        case .keyboard: "setup.keyboard.why"
        case .fullAccess: "setup.fullAccess.why"
        case .trigger: "setup.trigger.why"
        case .firstDictation: "setup.firstDictation.why"
        }
    }
}
