import Foundation
import Testing
@testable import PressayShared

@MainActor
@Suite struct VisibleInstanceTests {
    final class Keyboard {}

    @Test func onlyTheLastInstanceToAppearInserts() {
        let registry = VisibleInstance<Keyboard>()
        let old = Keyboard()
        let new = Keyboard()

        registry.appeared(old)
        #expect(registry.isVisible(old))
        // iOS shows the new instance before it hides the one it keeps alive.
        registry.appeared(new)
        registry.disappeared(old)

        #expect(registry.isVisible(new))
        #expect(!registry.isVisible(old))

        registry.disappeared(new)
        #expect(!registry.isVisible(new))
        #expect(registry.current == nil)
    }

    @Test func aReleasedInstanceIsNeverVisible() {
        let registry = VisibleInstance<Keyboard>()
        do {
            let keyboard = Keyboard()
            registry.appeared(keyboard)
        }
        #expect(registry.current == nil)
    }
}

@Suite struct ResultDeliveryTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResultDeliveryTests-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func result(_ text: String, age: TimeInterval) -> DictationResult {
        DictationResult(text: text, engine: "fast", createdAt: now - age, audioSeconds: 1, transcriptionSeconds: 0.1)
    }

    @Test func insertsAHiddenResultYoungerThanTwoMinutes() throws {
        let delivery = ResultDelivery(queue: ResultQueue(directory: directory))
        try delivery.queue.enqueue(result("récent", age: 119))

        #expect(try delivery.next(now: now, alreadyInserted: [])?.text == "récent")
        #expect(try delivery.next(now: now, alreadyInserted: []) == nil)
    }

    @Test func leavesOlderResultsToTheHistory() throws {
        let delivery = ResultDelivery(queue: ResultQueue(directory: directory))
        try delivery.queue.enqueue(result("ancien", age: 121))

        #expect(try delivery.next(now: now, alreadyInserted: []) == nil)
        #expect(try delivery.queue.pending().isEmpty)
    }

    @Test func neverHandsTheSameResultTwice() throws {
        let delivery = ResultDelivery(queue: ResultQueue(directory: directory))
        let first = result("un", age: 5)
        try delivery.queue.enqueue(first)
        try delivery.queue.enqueue(first)
        try delivery.queue.enqueue(result("deux", age: 1))

        let taken = try #require(try delivery.next(now: now, alreadyInserted: []))
        #expect(taken.text == "un")
        #expect(try delivery.next(now: now, alreadyInserted: [taken.id])?.text == "deux")
        #expect(try delivery.next(now: now, alreadyInserted: [taken.id]) == nil)
    }
}

@Suite struct InsertionTextTests {
    @Test func addsASpaceAfterAWord() {
        #expect(InsertionText.prepare("le texte", contextBefore: "Voici") == " le texte")
        #expect(InsertionText.prepare("Suite.", contextBefore: "Fin.") == " Suite.")
    }

    @Test func addsNothingWhereNoSpaceBelongs() {
        #expect(InsertionText.prepare("Bonjour", contextBefore: nil) == "Bonjour")
        #expect(InsertionText.prepare("Bonjour", contextBefore: "") == "Bonjour")
        #expect(InsertionText.prepare("Bonjour", contextBefore: "Salut ") == "Bonjour")
        #expect(InsertionText.prepare("école", contextBefore: "l’") == "école")
        #expect(InsertionText.prepare("oui", contextBefore: "« ") == "oui")
        #expect(InsertionText.prepare(", puis", contextBefore: "avant") == ", puis")
    }
}

@Suite struct InsertionUndoTests {
    @Test func availableWhileTheCursorFollowsTheInsertion() {
        let undo = InsertionUndo(text: " le texte dicté")
        #expect(undo.isAvailable(contextBefore: "Voici le texte dicté"))
        #expect(undo.deletionCount == 15)
    }

    @Test func goneOnceTheCursorMovedOrTheTextChanged() {
        let undo = InsertionUndo(text: " le texte dicté")
        #expect(!undo.isAvailable(contextBefore: "Voici le texte dicté!"))
        #expect(!undo.isAvailable(contextBefore: "Voici"))
        #expect(!undo.isAvailable(contextBefore: nil))
        // A short context that merely ends like the text is not proof enough.
        #expect(!undo.isAvailable(contextBefore: "té"))
    }

    @Test func acceptsAContextTruncatedByTheHost() {
        let undo = InsertionUndo(text: "Une longue dictée dont l’hôte ne renvoie que la fin")
        #expect(undo.isAvailable(contextBefore: "ne renvoie que la fin"))
    }
}

@Suite struct KeyboardBarStateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(
        _ phase: DictationPhase,
        changed: TimeInterval? = 1,
        inserted: TimeInterval? = nil,
        toggled: TimeInterval? = nil
    ) -> KeyboardBarState {
        KeyboardBarState.resolve(
            phase: phase,
            phaseChangedAt: changed.map { now - $0 },
            lastInsertionAt: inserted.map { now - $0 },
            toggleRequestedAt: toggled.map { now - $0 },
            now: now
        )
    }

    @Test func followsTheSessionPhase() {
        #expect(state(.idle) == .ready)
        #expect(state(.recording) == .listening)
        #expect(state(.transcribing) == .transcribing)
        #expect(state(.failed) == .failed)
        #expect(state(.delivered, inserted: 1) == .inserted)
        #expect(state(.delivered) == .ready)
    }

    @Test func ignoresStalePhases() {
        #expect(state(.recording, changed: 400) == .ready)
        #expect(state(.transcribing, changed: 200) == .ready)
        #expect(state(.failed, changed: 30) == .ready)
        #expect(state(.delivered, inserted: 30) == .ready)
    }

    @Test func hintsAtTheActionButtonWhenTheMicrophoneGetsNoAnswer() {
        // Still waiting for the app.
        #expect(state(.idle, changed: 60, toggled: 0.5) == .ready)
        #expect(state(.idle, changed: 60, toggled: 2) == .actionButtonHint)
        #expect(state(.idle, changed: 60, toggled: 20) == .ready)
        // The app answered.
        #expect(state(.recording, changed: 1, toggled: 2) == .listening)
        #expect(state(.failed, changed: 0.5, toggled: 2) == .failed)
    }

    @Test func schedulesTheNextRefresh() {
        let next = KeyboardBarState.nextChange(
            phaseChangedAt: now - 1,
            lastInsertionAt: nil,
            toggleRequestedAt: now - 1,
            now: now
        )
        #expect(next == now + 0.5)
        #expect(KeyboardBarState.nextChange(phaseChangedAt: nil, lastInsertionAt: nil, toggleRequestedAt: nil, now: now) == nil)
    }
}

@Suite struct KeyboardLayoutTests {
    func letters(_ row: [KeySpec]) -> String {
        row.compactMap { spec in
            if case let .character(value) = spec.action { value } else { nil }
        }.joined()
    }

    @Test func everyRowFillsTheWidth() {
        for language in KeyboardLanguage.allCases {
            for layer in [KeyboardLayer.letters, .numbers, .symbols] {
                for field in [FieldKind.text, .email, .url] {
                    for globe in [true, false] {
                        let layout = KeyboardLayout.make(language: language, layer: layer, field: field, showsGlobe: globe)
                        for row in layout.rows {
                            let width = row.reduce(0) { $0 + $1.width }
                            #expect(abs(width - KeyboardLayout.rowUnits) < 0.001, "\(language) \(layer) \(field)")
                        }
                    }
                }
            }
        }
    }

    @Test func frenchIsAzertyAndEnglishIsQwerty() {
        let french = KeyboardLayout.make(language: .french, layer: .letters, showsGlobe: false)
        #expect(letters(french.rows[0]) == "azertyuiop")
        #expect(letters(french.rows[1]) == "qsdfghjklm")
        #expect(letters(french.rows[2]) == "wxcvbn’")

        let english = KeyboardLayout.make(language: .english, layer: .letters, showsGlobe: false)
        #expect(letters(english.rows[0]) == "qwertyuiop")
        #expect(letters(english.rows[2]) == "zxcvbnm")
    }

    @Test func showsTheGlobeOnlyWhenIOSAsks() {
        let without = KeyboardLayout.make(language: .french, layer: .letters, showsGlobe: false)
        let with = KeyboardLayout.make(language: .french, layer: .letters, showsGlobe: true)
        #expect(!without.rows[3].contains { $0.action == .globe })
        #expect(with.rows[3].contains { $0.action == .globe })
    }

    @Test func addressFieldsGetTheirKeys() {
        let email = KeyboardLayout.make(language: .french, layer: .letters, field: .email, showsGlobe: false)
        #expect(letters(email.rows[3]) == "@.")
        let numbers = KeyboardLayout.make(language: .french, layer: .numbers, showsGlobe: false)
        #expect(letters(numbers.rows[1]).contains("€"))
    }

    @Test func accentsComeFromALongPress() throws {
        let french = KeyboardLayout.make(language: .french, layer: .letters, showsGlobe: false)
        let keyE = try #require(french.rows[0].first { $0.action == .character("e") })
        #expect(keyE.alternates.first == "é")
    }

    @Test func languageFollowsTheSettingThenTheSystem() {
        #expect(KeyboardLanguage.resolve(setting: .automatic, preferredLanguages: ["fr-FR"]) == .french)
        #expect(KeyboardLanguage.resolve(setting: .automatic, preferredLanguages: ["en-GB", "fr-FR"]) == .english)
        #expect(KeyboardLanguage.resolve(setting: .automatic, preferredLanguages: []) == .french)
        #expect(KeyboardLanguage.resolve(setting: .qwerty, preferredLanguages: ["fr-FR"]) == .english)
        #expect(KeyboardLanguage.resolve(setting: .azerty, preferredLanguages: ["en-US"]) == .french)
    }

    @Test func preferencesDefaultToAutomatic() throws {
        let suite = "KeyboardPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        #expect(preferences.layout == .automatic)
        preferences.layout = .qwerty
        #expect(KeyboardPreferences(defaults: defaults).layout == .qwerty)
        #expect(KeyboardPreferences(defaults: nil).layout == .automatic)
    }
}
