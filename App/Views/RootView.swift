import SwiftUI

/// Three tabs (dictate, history, settings), and the setup guide over them until it is done.
struct RootView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(SetupGuideModel.self) private var guide
    @Environment(AccountModel.self) private var account
    @Environment(ProductivityModel.self) private var productivity
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var guide = guide
        TabView {
            Tab("home.tab", systemImage: "mic.fill") {
                HomeView()
            }
            Tab("history.title", systemImage: "clock.arrow.circlepath") {
                HistoryView()
            }
            Tab("settings.title", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: $guide.isPresented) {
            SetupGuideView()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guide.refresh()
            // The history key is unreadable before the first unlock after a restart.
            dictation.loadHistory()
            // Signed out, this reaches nothing: the network is only ever for an account.
            Task {
                await account.refreshIfDue()
                await productivity.load()
                #if PRESSAY_SYNC
                await productivity.runSyncIfDue()
                #endif
            }
        }
    }
}
