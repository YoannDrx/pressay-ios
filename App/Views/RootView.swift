import SwiftUI

/// Three tabs (dictate, history, settings), and the setup guide over them until it is done.
struct RootView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(SetupGuideModel.self) private var guide
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
        }
    }
}
