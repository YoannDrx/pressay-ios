import PressayShared
import SwiftUI

@main
struct PressayApp: App {
    init() {
        PressayLog.shared.event("app.launched")
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
