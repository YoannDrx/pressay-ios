import PressayAccount
import PressayCore
import PressayShared
import SwiftUI
import UIKit

/// The dictation home: a large Dictate button to dictate without the Action button, where
/// the dictation stands, and the last text with a Copy button.
struct HomeView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(SetupGuideModel.self) private var guide

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !guide.evidence.isReadyToDictate {
                        SetupReminder()
                    }
                    DictateCard()
                    if let entry = dictation.lastEntry {
                        LastDictationCard(entry: entry)
                    }
                    if let fallback = dictation.lastModeFallback {
                        ModeFallbackNote(fallback: fallback)
                    }
                    Text("home.tagline")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text(verbatim: "Pressay"))
        }
    }
}

/// The text went in as dictated: said quietly, since nothing was lost.
private struct ModeFallbackNote: View {
    let fallback: RewriteFallback

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("modeFallback")
    }

    private var message: LocalizedStringKey {
        switch fallback {
        case .trialsExhausted: "home.fallback.trials"
        case .rateLimited: "home.fallback.busy"
        case .modelUnavailable: "home.fallback.unavailable"
        case .timedOut: "home.fallback.slow"
        case .refused, .failed, .emptyResult: "home.fallback.other"
        }
    }
}

/// Pressay cannot insert anything until the keyboard is set up: the home leads back to the
/// guide, since iOS never offers Full Access by itself.
private struct SetupReminder: View {
    @Environment(SetupGuideModel.self) private var guide

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("home.setup.title", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("home.setup.body")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                guide.open()
            } label: {
                Text(String(
                    format: String(localized: "home.setup.resume"),
                    guide.evidence.doneCount, SetupStep.allCases.count
                ))
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("resumeSetup")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
    }
}

private struct DictateCard: View {
    @Environment(DictationController.self) private var dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let recording = dictation.phase == .recording
        VStack(spacing: 20) {
            Button {
                Task { await dictation.toggle(source: .app) }
            } label: {
                ZStack {
                    Circle()
                        .fill(recording ? Color.red : Color.accentColor)
                        .shadow(color: (recording ? Color.red : Color.accentColor).opacity(0.35), radius: 16, y: 6)
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: recording && !reduceMotion)
                }
                .frame(width: 160, height: 160)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(dictation.phase == .transcribing || dictation.needsModelDownload)
            .opacity(dictation.phase == .transcribing || dictation.needsModelDownload ? 0.5 : 1)
            .accessibilityLabel(Text(recording ? "home.stop" : "home.dictate"))
            .accessibilityHint(Text("home.dictate.hint"))
            .accessibilityIdentifier("dictate")

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if dictation.phase == .transcribing {
                        ProgressView()
                    }
                    if recording, let start = dictation.recordingStartedAt {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                    }
                    Text(status)
                        .foregroundStyle(dictation.phase == .failed ? .red : .secondary)
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("status")
                if dictation.needsModelDownload {
                    NavigationLink("home.status.openSettings") { EngineSettings() }
                        .font(.callout)
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var status: LocalizedStringResource {
        if dictation.needsModelDownload, dictation.phase != .recording {
            return "home.status.needsModel"
        }
        switch dictation.phase {
        case .idle: return "home.status.idle"
        case .recording: return "home.status.recording"
        case .transcribing: return "home.status.transcribing"
        case .delivered: return "home.status.delivered"
        case .failed: return dictation.failure?.message ?? "failure.transcriptionFailed"
        }
    }
}

private struct LastDictationCard: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home.lastDictation")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("lastDictation")
            HStack {
                EntryDetails(entry: entry)
                Spacer()
                CopyButton(text: entry.text)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// Copies a dictation and says so for a moment.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "home.copied" : "home.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityIdentifier("copyLastDictation")
    }
}

struct EntryDetails: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.createdAt, style: .time)
            Text(verbatim: "·")
            Text(entry.engine == .fast ? "engine.fast" : "engine.apple")
            if entry.recovered {
                Text(verbatim: "·")
                Text("history.recovered")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    HomeView()
        .environment(DictationController.shared)
        .environment(SetupGuideModel.shared)
}
