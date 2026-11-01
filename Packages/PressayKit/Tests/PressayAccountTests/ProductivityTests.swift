// swiftlint:disable line_length optional_data_string_conversion
import Foundation
import Testing
@testable import PressayAccount

@Suite struct DictionaryApplierTests {
    @Test func replacesTermsAndVariantsWithoutCrossingBoundaries() {
        let entries = [
            DictionaryEntry(term: "Pressay", variants: ["presset", "press say"]),
            DictionaryEntry(term: "ASAP", replacement: "dès que possible"),
            DictionaryEntry(term: "off", enabled: false),
        ]
        #expect(DictionaryApplier.apply(entries, to: "Essaie presset, vraiment.") == "Essaie Pressay, vraiment.")
        #expect(DictionaryApplier.apply(entries, to: "j'ai press say ici") == "j'ai Pressay ici")
        #expect(DictionaryApplier.apply(entries, to: "Réponds asap!") == "Réponds dès que possible!")
        #expect(DictionaryApplier.apply(entries, to: "press. say") == "press. say")
        #expect(DictionaryApplier.apply(entries, to: "turn off now") == "turn off now")
        #expect(DictionaryApplier.apply(entries, to: "pressets") == "pressets")
        #expect(DictionaryApplier.apply([], to: "garde  les   espaces") == "garde  les   espaces")
    }

    @Test func fuzzyEntriesFollowTheMacPolicy() {
        let entries = [DictionaryEntry(term: "ChargeBee", matchKind: .fuzzy)]
        #expect(DictionaryApplier.apply(entries, to: "open charge bee today") == "open ChargeBee today")
        #expect(DictionaryApplier.apply(entries, to: "open chocolate today") == "open chocolate today")
        #expect(DictionaryApplier.soundex("robert") == "r163")
        #expect(DictionaryApplier.soundex("rupert") == "r163")
        #expect(DictionaryApplier.levenshtein("kitten", "sitting") == 3)
    }

    @Test func entriesCrossSyncInTheMacShape() throws {
        let entry = DictionaryEntry(id: "abc", term: "Pressay", variants: ["x"], matchKind: .fuzzy)
        let value = try JSONValue(encoding: entry)
        #expect(value["match_kind"] == .string("fuzzy"))
        #expect(value["replacement"] == .null)
        #expect(value["language"] == .null)
        #expect(value["enabled"] == .bool(true))
        // The Mac may omit fields that have a default.
        let minimal = try JSONDecoder().decode(DictionaryEntry.self, from: json(#"{"id":"a","term":"b"}"#))
        #expect(minimal.enabled)
        #expect(minimal.matchKind == .exact)
        #expect(DictionaryEntry(id: "bad id", term: "x").isValid == false)
        #expect(DictionaryEntry(id: "ok", term: "   ").isValid == false)
    }
}

@Suite struct ProLimitsTests {
    @Test func freeStopsAddingAtTwentyWordsAndProDoesNot() {
        #expect(ProLimits.canAddDictionaryEntry(count: 19, isPro: false))
        #expect(!ProLimits.canAddDictionaryEntry(count: 20, isPro: false))
        #expect(ProLimits.canAddDictionaryEntry(count: 20, isPro: true))
    }
}

private struct StubRewriter: TextRewriter {
    let result: @Sendable () async throws -> String
    func rewrite(_ text: String, instructions: String) async throws -> String { try await result() }
}

@Suite struct ModeRunnerTests {
    let secrets = InMemorySecretStore()
    var trials: AITrialCounter { AITrialCounter(secrets: secrets) }
    var email: PressayMode { PressayMode.builtin.first { $0.id == "email" }! }

    func run(_ mode: PressayMode, isPro: Bool, timeout: Duration = .seconds(5), _ result: @escaping @Sendable () async throws -> String) async -> ModeOutcome {
        await ModeRunner(trials: trials, rewriter: StubRewriter(result: result), timeout: timeout)
            .run(mode, on: "dictated", dictionaryTerms: [], isPro: isPro)
    }

    @Test func proRewritesWithoutCountingTrials() async {
        let outcome = await run(email, isPro: true) { "  Bonjour  " }
        #expect(outcome == ModeOutcome(text: "Bonjour", appliedModeID: "email", fallback: nil))
        #expect(trials.used == 0)
    }

    @Test func theFaithfulModeNeverCallsTheModel() async {
        let outcome = await run(PressayMode.builtin[0], isPro: true) { Issue.record("called"); return "x" }
        #expect(outcome == ModeOutcome(text: "dictated", appliedModeID: nil, fallback: nil))
    }

    @Test func freeGetsThreeTrialsThenTheDictatedText() async {
        for used in 1...ProLimits.freeAITrials {
            let outcome = await run(email, isPro: false) { "ok" }
            #expect(outcome.text == "ok")
            #expect(trials.used == used)
        }
        let outcome = await run(email, isPro: false) { Issue.record("called"); return "x" }
        #expect(outcome == ModeOutcome(text: "dictated", appliedModeID: nil, fallback: .trialsExhausted))
    }

    @Test(arguments: [RewriteFallback.rateLimited, .modelUnavailable, .refused, .failed])
    func everyFailureDeliversTheDictatedTextAndCostsNothing(_ reason: RewriteFallback) async {
        let outcome = await run(email, isPro: false) { throw RewriteFailure(reason) }
        #expect(outcome == ModeOutcome(text: "dictated", appliedModeID: nil, fallback: reason))
        #expect(trials.used == 0)
    }

    @Test func anUnknownErrorAndAnEmptyResultFallBack() async {
        struct Other: Error {}
        #expect(await run(email, isPro: true) { throw Other() }.fallback == .failed)
        #expect(await run(email, isPro: true) { "   " }.fallback == .emptyResult)
    }

    @Test func aSlowModelGivesWayToTheDictatedText() async {
        let outcome = await run(email, isPro: true, timeout: .milliseconds(50)) {
            try await Task.sleep(for: .seconds(30))
            return "too late"
        }
        #expect(outcome == ModeOutcome(text: "dictated", appliedModeID: nil, fallback: .timedOut))
    }

    @Test func theDictationStaysOutOfTheInstructions() throws {
        let instructions = try #require(email.modelInstructions(dictionaryTerms: ["Pressay"]))
        #expect(instructions.contains("the dictated text"))
        #expect(!instructions.contains("${"))
        #expect(instructions.contains("Pressay"))
        #expect(PressayMode.builtin[0].modelInstructions(dictionaryTerms: []) == nil)
    }

    @Test func theModelIsToldTheLanguageOfTheDictation() throws {
        let french = try #require(email.modelInstructions(dictionaryTerms: [], dictated: "Bonjour, je serai en retard pour la réunion de demain."))
        #expect(french.contains("The dictated text is in French."))
        let english = try #require(email.modelInstructions(dictionaryTerms: [], dictated: "Hello, I will be late for the meeting tomorrow morning."))
        #expect(english.contains("The dictated text is in English."))
        #expect(try #require(email.modelInstructions(dictionaryTerms: [])).contains("Keep the language"))
    }

    @Test func customModesAreReadFromTheMacShape() {
        let value: JSONValue = .object([
            "id": .string("mine"), "name": .string("Mine"),
            "steps": .array([
                .object(["id": .string("d"), "kind": .string("dictionary")]),
                .object(["id": .string("t"), "kind": .string("transform"), "instruction": .string("Do ${transcript}")]),
            ]),
        ])
        let mode = PressayMode(custom: value)
        #expect(mode?.instruction == "Do ${transcript}")
        #expect(mode?.customName == "Mine")
        #expect(PressayMode(custom: .object(["id": .string("email"), "name": .string("x")])) == nil)
        #expect(Set(PressayMode.builtin.map(\.id)).count == PressayMode.builtin.count)
    }
}

@Suite struct ProductivityStoreTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
    let secrets = InMemorySecretStore()

    @Test func keepsTheDocumentSealed() async throws {
        let store = ProductivityStore(fileURL: url, secrets: secrets)
        try await store.modify { $0.dictionary.append(DictionaryEntry(id: "a", term: "SecretWord")) }
        let raw = try Data(contentsOf: url)
        #expect(String(decoding: raw, as: UTF8.self).contains("SecretWord") == false)

        let reopened = ProductivityStore(fileURL: url, secrets: secrets)
        #expect(await reopened.document().dictionary.map(\.term) == ["SecretWord"])
    }

    @Test func aFailingChangeWritesNothing() async throws {
        struct Stop: Error {}
        let store = ProductivityStore(fileURL: url, secrets: secrets)
        await #expect(throws: Stop.self) {
            try await store.modify { document in
                document.activeModeID = "email"
                throw Stop()
            }
        }
        #expect(await store.document().activeModeID == PressayMode.faithfulID)
    }

    @Test func anUnknownActiveModeFallsBackToFaithful() {
        var document = ProductivityDocument()
        document.activeModeID = "gone"
        #expect(document.activeMode.id == PressayMode.faithfulID)
    }

    @Test func termsAreUniqueAndPreferTheReplacement() {
        var document = ProductivityDocument()
        document.dictionary = [
            DictionaryEntry(term: "asap", replacement: "ASAP"),
            DictionaryEntry(term: "Asap"),
            DictionaryEntry(term: "off", enabled: false),
        ]
        #expect(document.dictionaryTerms == ["ASAP"])
    }
}
// swiftlint:enable line_length optional_data_string_conversion
