import PressayCore
import PressayShared
import SwiftUI

/// The first-run guide: microphone, keyboard, Full Access, Action button (or Control
/// Center), then a first dictation with the Pressay keyboard. Shown full screen until it is
/// finished, and reopened from the home screen or the settings.
struct SetupGuideView: View {
    @Environment(SetupGuideModel.self) private var guide
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch guide.page {
                case .welcome: WelcomePage()
                case let .step(step): SetupStepPage(step: step).id(step)
                case .finished: FinishedPage()
                }
            }
            .animation(.snappy, value: guide.page)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                if guide.page != .finished {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("setup.later") { guide.postpone() }
                            .accessibilityIdentifier("setupLater")
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { guide.refresh() }
        }
        .onAppear { guide.refresh() }
    }
}

/// The local promise, before the first step.
private struct WelcomePage: View {
    @Environment(SetupGuideModel.self) private var guide
    @Environment(DictationController.self) private var dictation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("setup.welcome.title")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("setup.welcome.body")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Promise(symbol: "lock.iphone", text: "setup.welcome.promise.local")
                    Promise(symbol: "keyboard", text: "setup.welcome.promise.keyboard")
                    Promise(symbol: "button.horizontal.top.press", text: "setup.welcome.promise.trigger")
                }
                if dictation.models.state != .installed {
                    Text(String(
                        format: String(localized: "setup.welcome.model"),
                        ByteCountFormatter.string(fromByteCount: dictation.models.manifest.totalBytes, countStyle: .file)
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button {
                    // The model downloads while the user sets up the keyboard.
                    if dictation.models.state == .notInstalled {
                        dictation.models.download()
                    }
                    guide.begin()
                } label: {
                    Text("setup.welcome.start").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("setupStart")
            }
        }
    }
}

/// One step: why, how, and the action that does it. Ticks itself once done.
private struct SetupStepPage: View {
    let step: SetupStep
    @Environment(SetupGuideModel.self) private var guide
    @State private var showsWhy = false
    @State private var practice = ""

    var body: some View {
        let isDone = guide.evidence.isDone(step)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SetupProgressBar(current: step)
                StepHeader(step: step, isDone: isDone, actionButton: guide.hasActionButton)
                // Right under the header, so it stays in sight above the keyboard; Settings
                // comes first on the Full Access step, since that is where the user goes first.
                if step == .fullAccess {
                    OpenSettingsButton()
                }
                if let prompt = step.practicePrompt {
                    PracticeField(text: $practice, prompt: prompt)
                }
                Instructions(lines: step.instructions(actionButton: guide.hasActionButton))
                Button {
                    showsWhy = true
                } label: {
                    Label("setup.why", systemImage: "info.circle")
                }
                .accessibilityIdentifier("setupWhy")
                .popover(isPresented: $showsWhy) {
                    Text(step.why)
                        .font(.callout)
                        .padding()
                        .frame(idealWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .presentationCompactAdaptation(.popover)
                }
                StepActions(step: step)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                HStack(spacing: 12) {
                    Button {
                        guide.go(to: guide.previous(before: step))
                    } label: {
                        Text("setup.back").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    if isDone {
                        Button {
                            guide.go(to: guide.next(after: step))
                        } label: {
                            Text("setup.continue").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setupContinue")
                    } else if step == .trigger {
                        Button {
                            guide.skipTrigger()
                        } label: {
                            Text("setup.trigger.skip").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("setupSkip")
                    } else {
                        Label("setup.waiting", systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
        }
    }
}

/// Five segments, one per step: ticked when done, the current one highlighted. Each one
/// opens its step.
struct SetupProgressBar: View {
    let current: SetupStep?
    @Environment(SetupGuideModel.self) private var guide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(SetupStep.allCases) { step in
                    let done = guide.evidence.isDone(step)
                    Button {
                        guide.go(to: .step(step))
                    } label: {
                        Capsule()
                            .fill(done ? Color.green : (step == current ? Color.accentColor : Color(.tertiarySystemFill)))
                            .frame(height: 6)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(step.title))
                    .accessibilityValue(Text(done ? "setup.done" : "setup.toDo"))
                }
            }
            if let current {
                Text(String(
                    format: String(localized: "setup.progress"),
                    current.rawValue + 1, SetupStep.allCases.count
                ))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StepHeader: View {
    let step: SetupStep
    let isDone: Bool
    let actionButton: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(isDone ? Color.green : Color.accentColor.opacity(0.15))
                Image(systemName: isDone ? "checkmark" : step.symbol(actionButton: actionButton))
                    .font(.title2.bold())
                    .foregroundStyle(isDone ? Color.white : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(step.summary(actionButton: actionButton))
                    .foregroundStyle(.secondary)
                if isDone {
                    Label("setup.done", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("setupStepDone")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Instructions: View {
    let lines: [LocalizedStringResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(index + 1, format: .number)
                        .font(.callout.bold().monospacedDigit())
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .accessibilityHidden(true)
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// What the user can do on each step.
private struct StepActions: View {
    let step: SetupStep
    @Environment(SetupGuideModel.self) private var guide
    @Environment(DictationController.self) private var dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .microphone:
                if guide.microphoneDenied {
                    OpenSettingsButton()
                } else if !guide.evidence.isDone(.microphone) {
                    Button {
                        Task { await guide.requestMicrophone() }
                    } label: {
                        Text("permission.grant").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("setupMicrophone")
                }
            case .keyboard:
                OpenSettingsButton()
            case .fullAccess:
                EmptyView()
            case .trigger:
                Button {
                    guide.hasActionButton.toggle()
                } label: {
                    Text(guide.hasActionButton ? "setup.trigger.noActionButton" : "setup.trigger.hasActionButton")
                }
                .accessibilityIdentifier("setupTriggerVariant")
            case .firstDictation:
                if dictation.needsModelDownload {
                    ModelProgressNote()
                }
            }
        }
    }
}
