import PressayCore
import PressayShared
import SwiftUI
import UIKit

/// The dictation home: a Dictate button to try Pressay without the Action button, the
/// state of the current dictation, the last text, the Fast model and the settings.
struct HomeView: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DictateCard()
                } footer: {
                    Text("home.tagline")
                }
                if let entry = dictation.lastEntry {
                    Section("home.lastDictation") {
                        LastDictationRow(entry: entry)
                    }
                }
                Section {
                    ModelRow()
                } header: {
                    Text("model.section")
                } footer: {
                    Text("model.footer")
                }
                SettingsSection()
                Section {
                    NavigationLink("history.title") {
                        HistoryView()
                    }
                }
                Section {
                } footer: {
                    Text(versionLabel)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(Text(verbatim: "Pressay"))
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(format: String(localized: "home.version"), version, build)
    }
}

private struct DictateCard: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        VStack(spacing: 16) {
            Button {
                Task { await dictation.toggle(source: .app) }
            } label: {
                Label(buttonTitle, systemImage: dictation.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(dictation.phase == .recording ? .red : .accentColor)
            .disabled(dictation.phase == .transcribing || dictation.needsModelDownload)
            .accessibilityIdentifier("dictate")

            HStack(spacing: 8) {
                if dictation.phase == .transcribing {
                    ProgressView()
                }
                if dictation.phase == .recording, let start = dictation.recordingStartedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
                Text(status)
                    .foregroundStyle(dictation.phase == .failed ? .red : .secondary)
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("status")
        }
        .padding(.vertical, 8)
    }

    private var buttonTitle: LocalizedStringKey {
        dictation.phase == .recording ? "home.stop" : "home.dictate"
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

private struct LastDictationRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.text)
                .textSelection(.enabled)
                .accessibilityIdentifier("lastDictation")
            HStack {
                EntryDetails(entry: entry)
                Spacer()
                Button("home.copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entry.text
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
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

private struct ModelRow: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        let models = dictation.models
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("engine.fast")
                    .font(.headline)
                Spacer()
                Text(sizeLabel(models.manifest.totalBytes))
                    .foregroundStyle(.secondary)
            }
            switch models.state {
            case .installed:
                Label("model.installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("model.remove", role: .destructive) { models.remove() }
                    .buttonStyle(.borderless)
            case let .downloading(fraction):
                ProgressView(value: fraction) {
                    Text("model.downloading")
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
                .accessibilityIdentifier("modelProgress")
                Button("model.pause") { models.cancel() }
                    .buttonStyle(.borderless)
            case .notInstalled:
                Button(models.downloadedBytes > 0 ? "model.resume" : "model.download") { models.download() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("downloadModel")
            case let .failed(failure):
                Text(message(for: failure))
                    .foregroundStyle(.red)
                    .font(.callout)
                Button("model.retry") { models.download() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func message(for failure: ModelLibrary.Failure) -> String {
        switch failure {
        case let .insufficientSpace(required):
            String(format: String(localized: "model.failure.space"), sizeLabel(required))
        case .network:
            String(localized: "model.failure.network")
        case .integrity:
            String(localized: "model.failure.integrity")
        }
    }

    private func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SettingsSection: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        @Bindable var settings = dictation.settings
        Section("settings.title") {
            Picker("settings.engine", selection: $settings.engine) {
                Text("engine.fast").tag(EngineID.fast)
                Text("engine.apple").tag(EngineID.apple)
            }
            Picker("settings.language", selection: $settings.language) {
                Text("language.fr").tag("fr")
                Text("language.en").tag("en")
            }
            Toggle("settings.stopOnSilence", isOn: $settings.stopOnSilence)
            if settings.stopOnSilence {
                Picker("settings.silenceDelay", selection: $settings.silenceDelay) {
                    ForEach(DictationSettings.silenceDelays, id: \.self) { delay in
                        Text(delay.formatted(.number.precision(.fractionLength(0...1))) + " s").tag(delay)
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView()
        .environment(DictationController.shared)
}
