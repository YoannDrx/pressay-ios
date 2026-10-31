import Foundation

/// The layout family of the Pressay keyboard.
public enum KeyboardLanguage: String, Sendable, CaseIterable {
    /// AZERTY, French punctuation and currency.
    case french = "fr"
    /// QWERTY, English punctuation and currency.
    case english = "en"

    /// What the keyboard tells the system it types, for the host's spell checker.
    public var primaryLanguage: String {
        switch self {
        case .french: "fr-FR"
        case .english: "en-US"
        }
    }

    /// The setting wins; in automatic mode the first preferred language picks the layout.
    public static func resolve(setting: KeyboardLayoutSetting, preferredLanguages: [String]) -> KeyboardLanguage {
        switch setting {
        case .azerty: return .french
        case .qwerty: return .english
        case .automatic:
            let first = preferredLanguages.first?.lowercased() ?? "fr"
            return first.hasPrefix("fr") ? .french : .english
        }
    }
}

/// The layout the user picked in the app, stored in the App Group.
public enum KeyboardLayoutSetting: String, Sendable, CaseIterable {
    case automatic, azerty, qwerty
}

/// Keyboard preferences the app writes and the keyboard reads. Without Full Access the
/// keyboard cannot read the App Group, so every value has a default.
public struct KeyboardPreferences: @unchecked Sendable {
    // UserDefaults is thread-safe; it is only not annotated as Sendable.
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public static var shared: KeyboardPreferences {
        KeyboardPreferences(defaults: AppGroup.defaults)
    }

    private static let layoutKey = "keyboard.layout"
    private static let hapticsKey = "keyboard.haptics"

    public var layout: KeyboardLayoutSetting {
        get {
            defaults?.string(forKey: Self.layoutKey).flatMap(KeyboardLayoutSetting.init(rawValue:)) ?? .automatic
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Self.layoutKey)
        }
    }

    /// A light tap under the finger for each key, on by default. iOS gives keyboards haptics
    /// only with Full Access, which is also when this value can be read.
    public var haptics: Bool {
        get {
            defaults?.object(forKey: Self.hapticsKey) as? Bool ?? true
        }
        nonmutating set {
            defaults?.set(newValue, forKey: Self.hapticsKey)
        }
    }
}

public enum KeyboardLayer: Sendable, Equatable {
    case letters, numbers, symbols
}

/// The kind of field being edited, as far as the layout cares.
public enum FieldKind: Sendable, Equatable {
    case text, email, url
    /// Digits first: the keyboard opens on the numbers layer.
    case number
}

public enum KeyAction: Sendable, Equatable, Hashable {
    /// Inserts the string, uppercased when the shift is on and the layer is letters.
    case character(String)
    case shift
    case delete
    case space
    case returnKey
    case globe
    case layer(KeyboardLayer)
}

/// One key. Widths are in units of a letter key; every row adds up to `KeyboardLayout.rowUnits`.
/// `leadingGap` and `trailingGap` are empty space drawn inside the key's touch area, so a tap
/// next to A on a QWERTY keyboard still types A.
public struct KeySpec: Sendable, Equatable {
    public let action: KeyAction
    public let width: Double
    public let leadingGap: Double
    public let trailingGap: Double
    /// Shown on a long press: accents, other quotes, other currencies.
    public let alternates: [String]

    public init(
        _ action: KeyAction,
        width: Double = 1,
        leadingGap: Double = 0,
        trailingGap: Double = 0,
        alternates: [String] = []
    ) {
        self.action = action
        self.width = width
        self.leadingGap = leadingGap
        self.trailingGap = trailingGap
        self.alternates = alternates
    }
}

public struct KeyboardLayout: Sendable, Equatable {
    public static let rowUnits: Double = 10

    public let rows: [[KeySpec]]

    public init(rows: [[KeySpec]]) {
        self.rows = rows
    }

    public static func make(
        language: KeyboardLanguage,
        layer: KeyboardLayer,
        field: FieldKind = .text,
        showsGlobe: Bool
    ) -> KeyboardLayout {
        let top: [[KeySpec]] = switch layer {
        case .letters: letterRows(language)
        case .numbers: numberRows(language)
        case .symbols: symbolRows(language)
        }
        return KeyboardLayout(rows: top + [bottomRow(layer: layer, field: field, showsGlobe: showsGlobe)])
    }

    // MARK: Rows

    private static func characters(_ string: String) -> [KeySpec] {
        string.map { character in
            let value = String(character)
            return KeySpec(.character(value), alternates: Alternates.forKey(value))
        }
    }

    private static func letterRows(_ language: KeyboardLanguage) -> [[KeySpec]] {
        switch language {
        case .french:
            // Apple's French AZERTY: the apostrophe sits next to N.
            let third = characters("wxcvbn") + [KeySpec(.character("’"), alternates: Alternates.forKey("’"))]
            return [
                characters("azertyuiop"),
                characters("qsdfghjklm"),
                [KeySpec(.shift, width: 1.5)] + third + [KeySpec(.delete, width: 1.5)],
            ]
        case .english:
            var middle = characters("asdfghjkl")
            middle[0] = KeySpec(.character("a"), width: 1.5, leadingGap: 0.5, alternates: Alternates.forKey("a"))
            middle[8] = KeySpec(.character("l"), width: 1.5, trailingGap: 0.5, alternates: Alternates.forKey("l"))
            return [
                characters("qwertyuiop"),
                middle,
                [KeySpec(.shift, width: 1.5, trailingGap: 0.5)] + characters("zxcvbnm")
                    + [KeySpec(.delete, width: 1.5, leadingGap: 0.5)],
            ]
        }
    }

    private static func punctuationRow(switchTo layer: KeyboardLayer) -> [KeySpec] {
        let label: KeyAction = .layer(layer)
        let marks = [".", ",", "?", "!", "'"].map { KeySpec(.character($0), width: 1.4, alternates: Alternates.forKey($0)) }
        return [KeySpec(label, width: 1.5)] + marks + [KeySpec(.delete, width: 1.5)]
    }

    private static func numberRows(_ language: KeyboardLanguage) -> [[KeySpec]] {
        let currency = language == .french ? "€" : "$"
        return [
            characters("1234567890"),
            characters("-/:;()") + characters(currency) + characters("&@\""),
            punctuationRow(switchTo: .symbols),
        ]
    }

    private static func symbolRows(_ language: KeyboardLanguage) -> [[KeySpec]] {
        let currency = language == .french ? "$" : "€"
        return [
            characters("[]{}#%^*+="),
            characters("_\\|~<>") + characters(currency) + characters("£¥•"),
            punctuationRow(switchTo: .numbers),
        ]
    }

    private static func bottomRow(layer: KeyboardLayer, field: FieldKind, showsGlobe: Bool) -> [KeySpec] {
        var leading = [KeySpec(.layer(layer == .letters ? .numbers : .letters), width: 1.25)]
        if showsGlobe {
            leading.append(KeySpec(.globe, width: 1.25))
        }
        let extras: (before: [KeySpec], after: [KeySpec]) = switch field {
        case .email: ([KeySpec(.character("@"))], [KeySpec(.character("."))])
        case .url: ([KeySpec(.character("/"))], [KeySpec(.character("."), alternates: [".com", ".fr", ".org", ".net"])])
        case .text, .number: ([], [])
        }
        let trailing = [KeySpec(.returnKey, width: 2.25)]
        let fixed = (leading + extras.before + extras.after + trailing).reduce(0) { $0 + $1.width }
        let space = KeySpec(.space, width: rowUnits - fixed)
        return leading + extras.before + [space] + extras.after + trailing
    }
}

/// Long-press choices, the most frequent first, like the system keyboard.
public enum Alternates {
    private static let table: [String: [String]] = [
        "a": ["à", "â", "æ", "á", "ä", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["é", "è", "ê", "ë", "ę", "ė", "ē"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "n": ["ñ", "ń"],
        "o": ["ô", "œ", "ö", "ò", "ó", "õ", "ø", "ō"],
        "s": ["ß", "ś", "š"],
        "u": ["ù", "û", "ü", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "’": ["'", "‘", "\"", "“", "”", "«", "»"],
        "'": ["’", "‘", "`"],
        "\"": ["«", "»", "“", "”", "„"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "€": ["$", "£", "¥", "₩", "₽"],
        "$": ["€", "£", "¥", "₩", "₽"],
        "&": ["§"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "0": ["°"],
        "%": ["‰"],
    ]

    public static func forKey(_ key: String) -> [String] {
        table[key] ?? []
    }
}
