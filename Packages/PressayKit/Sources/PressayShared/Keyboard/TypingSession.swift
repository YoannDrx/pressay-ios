import Foundation

public enum ShiftState: Sendable, Equatable {
    case off
    /// The next letter is uppercase, then the shift turns off.
    case once
    /// Caps lock, after a double tap.
    case locked
}

/// The shift key: one tap for one capital, a double tap to lock, and automatic capitals
/// that never override a lock.
public struct ShiftController: Sendable, Equatable {
    public static let doubleTapInterval: TimeInterval = 0.35

    public private(set) var state: ShiftState = .off
    private var lastTapAt: Date?

    public init(state: ShiftState = .off) {
        self.state = state
    }

    public var isUppercase: Bool { state != .off }

    public mutating func tap(at now: Date) {
        if let lastTapAt, now.timeIntervalSince(lastTapAt) <= Self.doubleTapInterval, state != .locked {
            state = .locked
            self.lastTapAt = nil
            return
        }
        state = state == .off ? .once : .off
        lastTapAt = now
    }

    public mutating func didInsertCharacter() {
        if state == .once {
            state = .off
        }
    }

    public mutating func applyAutoCapitalization(_ shouldCapitalize: Bool) {
        guard state != .locked else { return }
        state = shouldCapitalize ? .once : .off
    }
}

/// Mirrors `UITextAutocapitalizationType` without depending on UIKit.
public enum AutocapitalizationMode: Sendable, Equatable {
    case none, words, sentences, allCharacters
}

public enum AutoCapitalization {
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    /// Skipped when looking for the end of a sentence: `(Fin.) ` or `« Oui. » `.
    private static let closers: Set<Character> = [")", "]", "»", "\"", "”", "’", "'"]

    public static func shouldCapitalize(contextBefore: String?, mode: AutocapitalizationMode) -> Bool {
        let before = contextBefore ?? ""
        switch mode {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = before.last else { return true }
            return last.isWhitespace
        case .sentences:
            var trimmed = Substring(before)
            var sawWhitespace = false
            while let last = trimmed.last, last.isWhitespace {
                if last.isNewline { return true }
                sawWhitespace = true
                trimmed = trimmed.dropLast()
            }
            if trimmed.isEmpty { return true }
            guard sawWhitespace else { return false }
            // French spacing puts a space inside the closing guillemet: `« Oui. » `.
            while let last = trimmed.last, closers.contains(last) || last.isWhitespace {
                trimmed = trimmed.dropLast()
            }
            return trimmed.last.map(sentenceEnds.contains) ?? false
        }
    }
}

public enum TextShortcuts {
    /// How quickly the second space must follow the first.
    public static let doubleSpaceInterval: TimeInterval = 0.6

    /// True when a space typed now should turn the space just typed into ". ".
    /// Only after a word or a closing mark, never after punctuation or a second space.
    public static func shouldInsertPeriod(contextBefore: String?, lastSpaceAt: Date?, now: Date) -> Bool {
        guard let lastSpaceAt, now.timeIntervalSince(lastSpaceAt) <= doubleSpaceInterval,
              let before = contextBefore, before.last == " "
        else { return false }
        guard let previous = before.dropLast().last else { return false }
        return previous.isLetter || previous.isNumber || [")", "»", "\"", "”", "’"].contains(previous)
    }
}

public enum WordDeletion {
    /// Characters to delete to remove the previous word and the spaces after it.
    public static func deletionCount(contextBefore: String?) -> Int {
        guard let before = contextBefore, !before.isEmpty else { return 1 }
        let trimmed = before.reversed().drop { $0 == " " || $0 == "\n" }
        let word = trimmed.prefix { $0 != " " && $0 != "\n" }
        return max(1, before.count - trimmed.count + word.count)
    }
}

/// The delete key held down: once on touch, again after 0.4 s, then every 0.08 s,
/// switching to whole words after 12 repeats (timings proven in the spike).
public enum DeleteRepeat {
    public static let initialDelay: TimeInterval = 0.4
    public static let interval: TimeInterval = 0.08
    public static let repeatsBeforeWords = 12

    public static func deletesWord(afterRepeats repeats: Int) -> Bool {
        repeats > repeatsBeforeWords
    }
}

/// What a key asks the text field to do.
public enum TextEdit: Sendable, Equatable {
    case insert(String)
    case deleteBackward(count: Int)
}

/// Typing rules of the keyboard, with no UIKit: the view controller feeds it the text before
/// the cursor and applies the edits it returns. No autocorrection (decision D10).
public struct TypingSession: Sendable, Equatable {
    public var layer: KeyboardLayer
    public private(set) var shift = ShiftController()
    public var autocapitalization: AutocapitalizationMode
    /// Off in address and URL fields, where two spaces never mean a full stop.
    public var periodShortcutEnabled: Bool
    private var lastSpaceAt: Date?

    public init(
        layer: KeyboardLayer = .letters,
        autocapitalization: AutocapitalizationMode = .sentences,
        periodShortcutEnabled: Bool = true
    ) {
        self.layer = layer
        self.autocapitalization = autocapitalization
        self.periodShortcutEnabled = periodShortcutEnabled
    }

    public var isUppercase: Bool { shift.isUppercase }

    public mutating func type(_ character: String) -> [TextEdit] {
        let text = layer == .letters && shift.isUppercase ? character.uppercased() : character
        shift.didInsertCharacter()
        lastSpaceAt = nil
        // Like the system keyboard: an apostrophe from the numbers layer goes back to letters.
        if layer != .letters, character == "'" || character == "’" {
            layer = .letters
        }
        return [.insert(text)]
    }

    public mutating func space(contextBefore: String?, now: Date) -> [TextEdit] {
        if layer != .letters {
            layer = .letters
        }
        if periodShortcutEnabled,
           TextShortcuts.shouldInsertPeriod(contextBefore: contextBefore, lastSpaceAt: lastSpaceAt, now: now) {
            lastSpaceAt = nil
            return [.deleteBackward(count: 1), .insert(". ")]
        }
        lastSpaceAt = now
        return [.insert(" ")]
    }

    public mutating func newline() -> [TextEdit] {
        lastSpaceAt = nil
        return [.insert("\n")]
    }

    public mutating func delete(byWord: Bool, contextBefore: String?) -> [TextEdit] {
        lastSpaceAt = nil
        let count = byWord ? WordDeletion.deletionCount(contextBefore: contextBefore) : 1
        return [.deleteBackward(count: count)]
    }

    public mutating func tapShift(at now: Date) {
        shift.tap(at: now)
    }

    /// Call after every change of the text or of the cursor.
    public mutating func textDidChange(contextBefore: String?) {
        shift.applyAutoCapitalization(
            AutoCapitalization.shouldCapitalize(contextBefore: contextBefore, mode: autocapitalization)
        )
    }
}

/// The text before the cursor, as the keyboard last wrote it.
///
/// Hosts report `documentContextBeforeInput` late: in Messages (iOS 26.3 simulator) the
/// proxy reflects an edit at once, then the host's update brings back the context from
/// before it (or nil) until the next keystroke, and typing "Bonjour" gave "BOnjour". The keyboard trusts what it wrote while
/// the host reports a context the keyboard has since written over. Any other context means
/// the cursor moved or the text changed elsewhere: the host is then right. The keyboard also
/// resets the tracker when the selection or the document changes.
public struct ContextTracker: Sendable, Equatable {
    /// Past this delay without typing, the host's context wins whatever it says.
    public static let catchUpWindow: TimeInterval = 30

    private var expected: String?
    private var expectedAt: Date?
    /// Contexts the pending edits were applied to: what a lagging host still reports.
    private var superseded: [String] = []

    public init() {}

    public mutating func context(actual: String?, now: Date) -> String? {
        guard let expected, let expectedAt, now.timeIntervalSince(expectedAt) < Self.catchUpWindow else {
            reset()
            return actual
        }
        // The proxy reflects an edit at once, then the host's late update can bring the
        // previous context back: matching once is no proof the host caught up.
        let current = actual ?? ""
        if current == expected || superseded.contains(current) {
            return expected
        }
        reset()
        return actual
    }

    /// Records edits the keyboard just sent, applied to the context it saw before them.
    public mutating func didEdit(_ edits: [TextEdit], from before: String?, now: Date) {
        var text = before ?? ""
        superseded.append(text)
        if superseded.count > 32 {
            superseded.removeFirst()
        }
        for edit in edits {
            switch edit {
            case let .insert(string): text += string
            case let .deleteBackward(count): text.removeLast(min(count, text.count))
            }
        }
        expected = text
        expectedAt = now
    }

    public mutating func reset() {
        expected = nil
        expectedAt = nil
        superseded.removeAll()
    }
}
