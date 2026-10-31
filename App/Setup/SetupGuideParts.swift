import PressayCore
import SwiftUI

struct Promise: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 28)
        }
        .font(.body)
    }
}

/// A field in the app where the Pressay keyboard can show, and insert a first dictation.
struct PracticeField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(3...6)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.4)))
            .accessibilityIdentifier("setupPracticeField")
    }
}

/// The first dictation needs an engine: in the simulator, or on an iPhone without Apple's
/// recognizer, that is the Fast model.
struct ModelProgressNote: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        switch dictation.models.state {
        case let .downloading(fraction):
            ProgressView(value: fraction) {
                Text("setup.firstDictation.model")
            }
            .font(.footnote)
        default:
            Button("model.download") { dictation.models.download() }
        }
    }
}

struct FinishedPage: View {
    @Environment(SetupGuideModel.self) private var guide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SetupProgressBar(current: nil)
                Image(systemName: guide.evidence.isComplete ? "checkmark.seal.fill" : "checkmark.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(guide.evidence.isReadyToDictate ? "setup.finished.title" : "setup.finished.incomplete")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 16) {
                    Promise(symbol: "waveform.badge.minus", text: "setup.tip.silence")
                    Promise(symbol: "stop.circle", text: "setup.tip.stop")
                    Promise(symbol: "globe", text: "setup.tip.globe")
                    Promise(symbol: "square.and.pencil", text: "setup.tip.elsewhere")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button {
                    guide.finish()
                } label: {
                    Text("setup.finish").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("setupFinish")
            }
        }
    }
}

struct BottomBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
    }
}

/// Opens the app's page in Settings, where iOS lists its keyboard.
struct OpenSettingsButton: View {
    @Environment(SetupGuideModel.self) private var guide

    var body: some View {
        Button {
            guide.openSettings()
        } label: {
            Label("setup.openSettings", systemImage: "gear")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("setupOpenSettings")
    }
}
