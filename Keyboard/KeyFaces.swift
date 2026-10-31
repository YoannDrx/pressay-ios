import PressayShared
import UIKit

/// What each key shows and what VoiceOver says for it.
enum KeyFaces {
    static func face(
        for spec: KeySpec,
        shift: ShiftState,
        uppercase: Bool,
        returnTitle: String,
        returnEnabled: Bool
    ) -> KeyFace {
        switch spec.action {
        case let .character(value):
            let shown = uppercase ? value.uppercased() : value
            return KeyFace(title: shown, accessibilityLabel: shown, isCharacter: true)
        case .shift:
            return shiftFace(shift)
        case .delete:
            return KeyFace(symbol: "delete.left", accessibilityLabel: String(localized: "keyboard.key.delete"), isCharacter: false)
        case .space:
            let title = String(localized: "keyboard.key.space")
            return KeyFace(title: title, accessibilityLabel: title, isCharacter: false)
        case .returnKey:
            return KeyFace(title: returnTitle, accessibilityLabel: returnTitle, isCharacter: false, isEnabled: returnEnabled)
        case .globe:
            return KeyFace(symbol: "globe", accessibilityLabel: String(localized: "keyboard.nextKeyboard"), isCharacter: false)
        case let .layer(layer):
            return layerFace(layer)
        }
    }

    private static func shiftFace(_ shift: ShiftState) -> KeyFace {
        let symbol = switch shift {
        case .off: "shift"
        case .once: "shift.fill"
        case .locked: "capslock.fill"
        }
        let value: String? = switch shift {
        case .off: nil
        case .once: String(localized: "keyboard.key.shift.on")
        case .locked: String(localized: "keyboard.key.shift.locked")
        }
        return KeyFace(
            symbol: symbol,
            accessibilityLabel: String(localized: "keyboard.key.shift"),
            accessibilityValue: value,
            isCharacter: false
        )
    }

    private static func layerFace(_ layer: KeyboardLayer) -> KeyFace {
        switch layer {
        case .letters:
            KeyFace(title: "ABC", accessibilityLabel: String(localized: "keyboard.key.letters"), isCharacter: false)
        case .numbers:
            KeyFace(title: "123", accessibilityLabel: String(localized: "keyboard.key.numbers"), isCharacter: false)
        case .symbols:
            KeyFace(title: "#+=", accessibilityLabel: String(localized: "keyboard.key.symbols"), isCharacter: false)
        }
    }
}

/// The return key's label follows the field's `returnKeyType`.
enum ReturnKey {
    static func title(for type: UIReturnKeyType) -> String {
        switch type {
        case .go: String(localized: "keyboard.return.go")
        case .google, .yahoo, .search: String(localized: "keyboard.return.search")
        case .join: String(localized: "keyboard.return.join")
        case .next: String(localized: "keyboard.return.next")
        case .route: String(localized: "keyboard.return.route")
        case .send: String(localized: "keyboard.return.send")
        case .done: String(localized: "keyboard.return.done")
        case .emergencyCall: String(localized: "keyboard.return.emergencyCall")
        case .continue: String(localized: "keyboard.return.continue")
        default: String(localized: "keyboard.return.default")
        }
    }
}
