import AppIntents

/// Opens the app. Compiled into the app and the widget extension, so the Control
/// runs it in the app process. The dictation intent replaces it on the Control in lot I2.
struct OpenPressayIntent: AppIntent {
    static let title: LocalizedStringResource = "control.open.title"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
