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
}
