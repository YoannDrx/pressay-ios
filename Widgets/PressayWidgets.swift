import ActivityKit
import AppIntents
import PressayShared
import SwiftUI
import WidgetKit

@main
struct PressayWidgets: WidgetBundle {
    var body: some Widget {
        ToggleDictationControl()
        DictationLiveActivity()
    }
}

/// Assignable to the Action button, Control Center and the Lock Screen.
struct ToggleDictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "fr.yodev.pressay.control.dictate") {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("control.dictate.title", systemImage: "mic.fill")
            }
        }
        .displayName("control.dictate.title")
        .description("control.dictate.description")
    }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                PhaseIcon(phase: context.state.phase)
                    .font(.title2)
                Text(PhaseText.key(for: context.state.phase))
                    .font(.headline)
                Spacer()
                if context.state.phase == .recording {
                    ElapsedTime(since: context.state.startedAt)
                        .frame(width: 56)
                    StopButton()
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(PhaseText.key(for: context.state.phase))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .recording {
                        StopButton()
                    }
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                if context.state.phase == .recording {
                    ElapsedTime(since: context.state.startedAt)
                        .frame(width: 40)
                } else {
                    PhaseIcon(phase: context.state.phase)
                }
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopDictationIntent()) {
            Image(systemName: "stop.fill")
                .accessibilityLabel(Text("activity.stop"))
        }
        .tint(.red)
    }
}

private struct ElapsedTime: View {
    let since: Date

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

private struct PhaseIcon: View {
    let phase: DictationPhase

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(phase == .recording ? .red : .primary)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .recording: "waveform"
        case .transcribing: "text.bubble"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "mic"
        }
    }
}

private enum PhaseText {
    static func key(for phase: DictationPhase) -> LocalizedStringKey {
        switch phase {
        case .recording: "activity.recording"
        case .transcribing: "activity.transcribing"
        case .delivered: "activity.delivered"
        case .failed: "activity.failed"
        case .idle: "activity.idle"
        }
    }
}
