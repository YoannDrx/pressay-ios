import PressayShared
import SwiftUI

@main
struct PressayApp: App {
    @State private var dictation = DictationController.shared

    init() {
        PressayLog.shared.event("app.launched")
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(dictation)
        }
    }
}
