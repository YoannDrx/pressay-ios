import PressayShared
import SwiftUI

@main
struct PressayApp: App {
    @State private var dictation = DictationController.shared
    @State private var guide = SetupGuideModel.shared

    init() {
        PressayLog.shared.event("app.launched")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dictation)
                .environment(guide)
        }
    }
}
