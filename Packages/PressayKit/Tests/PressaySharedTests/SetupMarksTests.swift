import Foundation
import Testing
@testable import PressayShared

@Suite struct SetupMarksTests {
    let suiteName = "SetupMarksTests-\(UUID().uuidString)"

    @Test func recordsEachMarkAndResets() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let marks = SetupMarks(defaults: defaults, notify: false)
        #expect(marks.keyboardFullAccessAt == nil)
        #expect(marks.lastInsertionAt == nil)
        #expect(marks.intentUsedAt == nil)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        marks.markKeyboardFullAccess(at: date)
        marks.markInsertion(at: date.addingTimeInterval(1))
        marks.markIntentUsed(at: date.addingTimeInterval(2))

        let reopened = SetupMarks(defaults: defaults, notify: false)
        #expect(reopened.keyboardFullAccessAt == date)
        #expect(reopened.lastInsertionAt == date.addingTimeInterval(1))
        #expect(reopened.intentUsedAt == date.addingTimeInterval(2))

        reopened.reset()
        #expect(marks.keyboardFullAccessAt == nil)
        #expect(marks.lastInsertionAt == nil)
        #expect(marks.intentUsedAt == nil)
    }

    @Test func keyboardHapticsAreOnByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = KeyboardPreferences(defaults: defaults)
        #expect(preferences.haptics)
        preferences.haptics = false
        #expect(!KeyboardPreferences(defaults: defaults).haptics)
        #expect(KeyboardPreferences(defaults: nil).haptics)
    }
}
