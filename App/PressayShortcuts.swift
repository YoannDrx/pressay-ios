import AppIntents

/// Siri and Shortcuts phrases. They also cover iPhones without an Action button, through
/// Back Tap or a Shortcuts automation. Translations live in AppShortcuts.xcstrings.
struct PressayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start a dictation in \(.applicationName)",
            ],
            shortTitle: "shortcut.dictate.title",
            systemImageName: "mic.fill"
        )
    }
}
