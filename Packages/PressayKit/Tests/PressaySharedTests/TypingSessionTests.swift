import Foundation
import Testing
@testable import PressayShared

@Suite struct ShiftControllerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func oneTapGivesOneCapital() {
        var shift = ShiftController()
        shift.tap(at: start)
        #expect(shift.state == .once)
        shift.didInsertCharacter()
        #expect(shift.state == .off)
    }

    @Test func doubleTapLocksUntilTappedAgain() {
        var shift = ShiftController()
        shift.tap(at: start)
        shift.tap(at: start + 0.2)
        #expect(shift.state == .locked)
        shift.didInsertCharacter()
        shift.applyAutoCapitalization(false)
        #expect(shift.state == .locked)
        shift.tap(at: start + 2)
        #expect(shift.state == .off)
    }

    @Test func slowSecondTapTurnsTheShiftOff() {
        var shift = ShiftController()
        shift.tap(at: start)
        shift.tap(at: start + 1)
        #expect(shift.state == .off)
    }

    @Test func automaticCapitalFollowsTheText() {
        var shift = ShiftController()
        shift.applyAutoCapitalization(true)
        #expect(shift.state == .once)
        shift.applyAutoCapitalization(false)
        #expect(shift.state == .off)
    }
}

@Suite struct AutoCapitalizationTests {
    func sentences(_ context: String?) -> Bool {
        AutoCapitalization.shouldCapitalize(contextBefore: context, mode: .sentences)
    }

    @Test func capitalizesAtTheStartOfASentence() {
        #expect(sentences(nil))
        #expect(sentences(""))
        #expect(sentences("Bonjour. "))
        #expect(sentences("Vraiment ! "))
        #expect(sentences("Quoi ? "))
        #expect(sentences("Fin… "))
        #expect(sentences("(C’est fini.) "))
        #expect(sentences("Il a dit « oui. » "))
        #expect(sentences("Première ligne\n"))
        #expect(sentences("   "))
    }

    @Test func staysLowercaseInsideASentence() {
        #expect(!sentences("Bonjour"))
        #expect(!sentences("Bonjour "))
        #expect(!sentences("Bonjour."))
        #expect(!sentences("Bonjour, "))
        #expect(!sentences("3.5"))
    }

    @Test func followsTheFieldMode() {
        #expect(!AutoCapitalization.shouldCapitalize(contextBefore: "", mode: .none))
        #expect(AutoCapitalization.shouldCapitalize(contextBefore: "abc", mode: .allCharacters))
        #expect(AutoCapitalization.shouldCapitalize(contextBefore: "Jean ", mode: .words))
        #expect(!AutoCapitalization.shouldCapitalize(contextBefore: "Jean", mode: .words))
    }
}

@Suite struct TextShortcutsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func doubleSpaceAfterAWordMakesAFullStop() {
        #expect(TextShortcuts.shouldInsertPeriod(contextBefore: "Bonjour ", lastSpaceAt: now - 0.2, now: now))
        #expect(TextShortcuts.shouldInsertPeriod(contextBefore: "à 15 ", lastSpaceAt: now - 0.2, now: now))
    }

    @Test func doubleSpaceIsIgnoredElsewhere() {
        // Too slow.
        #expect(!TextShortcuts.shouldInsertPeriod(contextBefore: "Bonjour ", lastSpaceAt: now - 1, now: now))
        // No space typed just before.
        #expect(!TextShortcuts.shouldInsertPeriod(contextBefore: "Bonjour ", lastSpaceAt: nil, now: now))
        // After punctuation or a second space.
        #expect(!TextShortcuts.shouldInsertPeriod(contextBefore: "Bonjour. ", lastSpaceAt: now - 0.2, now: now))
        #expect(!TextShortcuts.shouldInsertPeriod(contextBefore: "Bonjour  ", lastSpaceAt: now - 0.2, now: now))
        #expect(!TextShortcuts.shouldInsertPeriod(contextBefore: " ", lastSpaceAt: now - 0.2, now: now))
        // The cursor moved away from the space.
        #expect(!TextShortcuts.shouldInsertPeriod(contextBefore: "Bonjour", lastSpaceAt: now - 0.2, now: now))
    }
}

@Suite struct WordDeletionTests {
    @Test func deletesThePreviousWordAndItsTrailingSpaces() {
        #expect(WordDeletion.deletionCount(contextBefore: "Bonjour le monde") == 5)
        #expect(WordDeletion.deletionCount(contextBefore: "Bonjour le monde  ") == 7)
        #expect(WordDeletion.deletionCount(contextBefore: "ligne\nsuite") == 5)
        #expect(WordDeletion.deletionCount(contextBefore: "unique") == 6)
    }

    @Test func deletesOneCharacterWithoutContext() {
        #expect(WordDeletion.deletionCount(contextBefore: nil) == 1)
        #expect(WordDeletion.deletionCount(contextBefore: "") == 1)
        #expect(WordDeletion.deletionCount(contextBefore: "   ") == 3)
    }

    @Test func switchesToWordsAfterTwelveRepeats() {
        #expect(!DeleteRepeat.deletesWord(afterRepeats: 0))
        #expect(!DeleteRepeat.deletesWord(afterRepeats: 12))
        #expect(DeleteRepeat.deletesWord(afterRepeats: 13))
    }
}

/// Applies edits to a string, as a text field would.
private struct Document {
    var text = ""

    mutating func apply(_ edits: [TextEdit]) {
        for edit in edits {
            switch edit {
            case let .insert(string): text += string
            case let .deleteBackward(count): text.removeLast(min(count, text.count))
            }
        }
    }
}

@Suite struct TypingSessionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func typesASentenceWithAutomaticCapitalsAndDoubleSpace() {
        var session = TypingSession()
        var document = Document()
        session.textDidChange(contextBefore: document.text)

        for character in "bonjour" {
            document.apply(session.type(String(character)))
            session.textDidChange(contextBefore: document.text)
        }
        document.apply(session.space(contextBefore: document.text, now: now))
        session.textDidChange(contextBefore: document.text)
        document.apply(session.space(contextBefore: document.text, now: now + 0.3))
        session.textDidChange(contextBefore: document.text)
        #expect(session.isUppercase)
        document.apply(session.type("ç"))
        session.textDidChange(contextBefore: document.text)
        document.apply(session.type("a"))

        #expect(document.text == "Bonjour. Ça")
    }

    @Test func spaceAndApostropheReturnToLetters() {
        var session = TypingSession(layer: .numbers)
        _ = session.type("4")
        #expect(session.layer == .numbers)
        _ = session.space(contextBefore: "4", now: now)
        #expect(session.layer == .letters)

        session.layer = .numbers
        _ = session.type("'")
        #expect(session.layer == .letters)
    }

    @Test func digitsAreNeverUppercased() {
        var session = TypingSession(layer: .numbers)
        session.textDidChange(contextBefore: "")
        #expect(session.type("é") == [.insert("é")])
    }

    @Test func doubleSpaceCanBeTurnedOff() {
        var session = TypingSession(periodShortcutEnabled: false)
        _ = session.space(contextBefore: "a", now: now)
        #expect(session.space(contextBefore: "a ", now: now + 0.1) == [.insert(" ")])
    }

    @Test func deleteByWordUsesTheContext() {
        var session = TypingSession()
        #expect(session.delete(byWord: true, contextBefore: "un deux") == [.deleteBackward(count: 4)])
        #expect(session.delete(byWord: false, contextBefore: "un deux") == [.deleteBackward(count: 1)])
    }
}

@Suite struct ContextTrackerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func trustsItsOwnEditsUntilTheHostCatchesUp() {
        var tracker = ContextTracker()
        tracker.didEdit([.insert("B")], from: "", now: now)
        // The host still reports the context before the edit.
        #expect(tracker.context(actual: "", now: now + 0.01) == "B")
        tracker.didEdit([.insert("o")], from: "B", now: now + 0.02)
        #expect(tracker.context(actual: "", now: now + 0.03) == "Bo")
        #expect(tracker.context(actual: "B", now: now + 0.04) == "Bo")
        // A lagging host may report nothing at all.
        #expect(tracker.context(actual: nil, now: now + 0.045) == "Bo")
        // The proxy shows the edit, then the host's late update brings the old context back.
        #expect(tracker.context(actual: "Bo", now: now + 0.05) == "Bo")
        #expect(tracker.context(actual: "B", now: now + 0.06) == "Bo")
        // Something the keyboard never wrote: the host is the reference again.
        #expect(tracker.context(actual: "Bo!", now: now + 0.07) == "Bo!")
        #expect(tracker.context(actual: "B", now: now + 0.08) == "B")
    }

    @Test func followsDeletions() {
        var tracker = ContextTracker()
        tracker.didEdit([.deleteBackward(count: 1), .insert(". ")], from: "Bonjour ", now: now)
        #expect(tracker.context(actual: "Bonjour ", now: now + 0.01) == "Bonjour. ")
    }

    @Test func givesWayWhenTheTextChangedElsewhere() {
        var tracker = ContextTracker()
        tracker.didEdit([.insert("a")], from: "Salut", now: now)
        #expect(tracker.context(actual: "Autre champ", now: now + 0.01) == "Autre champ")
        tracker.didEdit([.insert("a")], from: "Salut", now: now)
        #expect(tracker.context(actual: "Salut", now: now + 1) == "Saluta")
        #expect(tracker.context(actual: "Salut", now: now + 31) == "Salut")
    }

    @Test func typingQuicklyThroughALaggingHostGivesTheRightCapitals() {
        var tracker = ContextTracker()
        var session = TypingSession()
        var hostContext = ""
        var written = ""
        session.textDidChange(contextBefore: tracker.context(actual: hostContext, now: now))
        for (index, character) in "bonjour".enumerated() {
            let time = now + Double(index) * 0.05
            let before = tracker.context(actual: hostContext, now: time)
            let edits = session.type(String(character))
            for case let .insert(text) in edits { written += text }
            tracker.didEdit(edits, from: before, now: time)
            session.textDidChange(contextBefore: tracker.context(actual: hostContext, now: time))
            // The host applies each edit one keystroke late.
            hostContext = String(written.dropLast())
        }
        #expect(written == "Bonjour")
    }
}
