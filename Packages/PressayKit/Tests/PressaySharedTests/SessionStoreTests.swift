import Foundation
import Testing
@testable import PressayShared

@Suite struct SessionStoreTests {
    let suiteName = "SessionStoreTests-\(UUID().uuidString)"

    @Test func startsIdleThenPersistsThePhase() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: defaults, notify: false)
        #expect(store.phase == .idle)
        #expect(store.phaseChangedAt == nil)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.setPhase(.recording, at: date)

        let reopened = SessionStore(defaults: defaults, notify: false)
        #expect(reopened.phase == .recording)
        #expect(reopened.phaseChangedAt == date)
    }

    @Test func aKeyboardToggleRequestIsTakenOnceWhileFresh() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: defaults, notify: false)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!store.takeToggleRequest(now: now))

        store.requestToggle(at: now)
        #expect(store.toggleRequestedAt == now)
        #expect(store.takeToggleRequest(now: now + 0.3))
        #expect(!store.takeToggleRequest(now: now + 0.4))
    }

    /// A suspended app gets the signal when iOS resumes it: too late to start a dictation.
    @Test func aStaleKeyboardToggleRequestIsDropped() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: defaults, notify: false)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.requestToggle(at: now)
        #expect(!store.takeToggleRequest(now: now + 60))
        #expect(store.toggleRequestedAt == nil)
    }
}
