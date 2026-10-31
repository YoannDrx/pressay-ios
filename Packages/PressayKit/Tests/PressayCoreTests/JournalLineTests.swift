import Foundation
import Testing
@testable import PressayCore

@Suite struct JournalLineTests {
    @Test func decodesNewestFirstAndSkipsBrokenLines() {
        let journal = """
        {"at":"2026-10-31T10:00:00.000Z","event":"app.launched","process":"fr.yodev.pressay"}
        {"at":"2026-10-31T10:00:01.000Z","eve
        {"at":"2026-10-31T10:00:02.000Z","characters":12,"event":"keyboard.inserted","fullAccess":true,\
        "process":"fr.yodev.pressay.keyboard"}

        """
        let lines = JournalLine.parse(journal)
        #expect(lines.map(\.event) == ["keyboard.inserted", "app.launched"])
        #expect(lines[0].process == "keyboard")
        #expect(lines[0].details == "characters=12 fullAccess=true")
        #expect(lines[1].process == "app")
        #expect(lines[1].details.isEmpty)
    }

    @Test func keepsTheNewestLinesUpToTheLimit() {
        let journal = (0..<10).map { #"{"event":"e\#($0)"}"# }.joined(separator: "\n")
        #expect(JournalLine.parse(journal, limit: 3).map(\.event) == ["e9", "e8", "e7"])
    }
}
