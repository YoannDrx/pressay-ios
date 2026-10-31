import Testing
@testable import PressayCore

@Suite struct EngineIDTests {
    /// The raw values are persisted in settings and logs: renaming one breaks existing installs.
    @Test func rawValuesAreStable() {
        #expect(EngineID.allCases.map(\.rawValue) == ["fast", "apple", "polyglot"])
    }
}
