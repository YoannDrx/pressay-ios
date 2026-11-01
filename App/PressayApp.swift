import PressayShared
import SwiftUI

@main
struct PressayApp: App {
    @State private var dictation = DictationController.shared
    @State private var guide = SetupGuideModel.shared
    @State private var account = AccountModel.shared
    @State private var store = StoreService.shared
    @State private var productivity = ProductivityModel.shared

    init() {
        PressayLog.shared.event("app.launched")
        // A renewal or an approved purchase can arrive at any launch, even in the background.
        StoreService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dictation)
                .environment(guide)
                .environment(account)
                .environment(store)
                .environment(productivity)
                .task {
                    await account.start()
                    await productivity.load()
                }
        }
    }
}
