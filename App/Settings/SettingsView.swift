import PressayAccount
import PressayCore
import PressayShared
import SwiftUI

/// The account and Pro, personalization, engine, language, stop on silence, sounds, haptics,
/// keyboard layout, the setup guide and the support journal.
struct SettingsView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(SetupGuideModel.self) private var guide
    @Environment(AccountModel.self) private var account

    var body: some View {
        @Bindable var settings = dictation.settings
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ProView()
                    } label: {
                        LabeledContent {
                            Text(account.isPro ? "pro.status.active" : "pro.status.free")
                        } label: {
                            Label("pro.title", systemImage: "sparkles")
                        }
                    }
                    .accessibilityIdentifier("proSettings")
                    NavigationLink {
                        AccountView()
                    } label: {
                        Label("account.title", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("accountSettings")
                } footer: {
                    if account.snapshot.connection == .signedOut {
                        Text("settings.account.footer")
                    }
                }

                Section("settings.personalization") {
                    NavigationLink {
                        ModesView()
                    } label: {
                        Label("modes.title", systemImage: "wand.and.sparkles")
                    }
                    .accessibilityIdentifier("modesSettings")
                    NavigationLink {
                        DictionaryView()
                    } label: {
                        Label("dictionary.title", systemImage: "character.book.closed")
                    }
                    .accessibilityIdentifier("dictionarySettings")
                }

                Section("settings.dictation") {
                    NavigationLink {
                        EngineSettings()
                    } label: {
                        LabeledContent("settings.engine") {
                            Text(settings.engine == .fast ? "engine.fast" : "engine.apple")
                        }
                    }
                    .accessibilityIdentifier("engineSettings")
                    Picker("settings.language", selection: $settings.language) {
                        Text("language.fr").tag("fr")
                        Text("language.en").tag("en")
                    }
                    Toggle("settings.stopOnSilence", isOn: $settings.stopOnSilence)
                    if settings.stopOnSilence {
                        Picker("settings.silenceDelay", selection: $settings.silenceDelay) {
                            ForEach(DictationSettings.silenceDelays, id: \.self) { delay in
                                Text(Measurement(value: delay, unit: UnitDuration.seconds), format: .measurement(
                                    width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0...1))
                                ))
                                .tag(delay)
                            }
                        }
                    }
                }

                Section {
                    Toggle("settings.sounds", isOn: $settings.sounds)
                    Toggle("settings.haptics", isOn: $settings.haptics)
                } header: {
                    Text("settings.feedback")
                } footer: {
                    Text("settings.feedback.footer")
                }

                Section("settings.keyboard") {
                    Picker("settings.keyboardLayout", selection: $settings.keyboardLayout) {
                        Text("keyboardLayout.automatic").tag(KeyboardLayoutSetting.automatic)
                        Text("keyboardLayout.azerty").tag(KeyboardLayoutSetting.azerty)
                        Text("keyboardLayout.qwerty").tag(KeyboardLayoutSetting.qwerty)
                    }
                }

                Section {
                    Button {
                        guide.open()
                    } label: {
                        Label("settings.guide", systemImage: "list.bullet.clipboard")
                    }
                    .accessibilityIdentifier("replayGuide")
                    NavigationLink {
                        JournalView()
                    } label: {
                        Label("journal.title", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("journal")
                } header: {
                    Text("settings.help")
                } footer: {
                    Text("settings.journal.footer")
                }

                Section {
                } footer: {
                    Text(versionLabel)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("settings.title")
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(format: String(localized: "home.version"), version, build)
    }
}

/// The engine choice and the Fast model it needs.
struct EngineSettings: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        @Bindable var settings = dictation.settings
        Form {
            Section {
                Picker("settings.engine", selection: $settings.engine) {
                    Text("engine.fast").tag(EngineID.fast)
                    Text("engine.apple").tag(EngineID.apple)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("settings.engine.footer")
            }
            Section {
                ModelRow()
            } header: {
                Text("model.section")
            } footer: {
                Text("model.footer")
            }
        }
        .navigationTitle("settings.engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelRow: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        let models = dictation.models
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("engine.fast") {
                Text(ByteCountFormatter.string(fromByteCount: models.manifest.totalBytes, countStyle: .file))
            }
            .font(.headline)
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
            String(format: String(localized: "model.failure.space"), ByteCountFormatter.string(fromByteCount: required, countStyle: .file))
        case .network:
            String(localized: "model.failure.network")
        case .integrity:
            String(localized: "model.failure.integrity")
        }
    }
}
