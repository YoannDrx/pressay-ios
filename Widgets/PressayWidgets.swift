import SwiftUI
import WidgetKit

@main
struct PressayWidgets: WidgetBundle {
    var body: some Widget {
        OpenPressayControl()
    }
}

/// Assignable to the Action button, Control Center and the Lock Screen.
struct OpenPressayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "fr.yodev.pressay.control.open") {
            ControlWidgetButton(action: OpenPressayIntent()) {
                Label("control.open.title", systemImage: "waveform")
            }
        }
        .displayName("control.open.title")
    }
}
