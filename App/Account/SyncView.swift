import PressayAccount
import SwiftUI
import UIKit

/// Encrypted sync of the dictionary, modes and active mode with the Mac. Off until asked for.
struct SyncView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ProductivityModel.self) private var productivity
    @State private var recoveryInput = ""
    @State private var recoveryCode: String?
    @State private var showsPro = false

    var body: some View {
        Form {
            Section {
                Text("sync.explanation").font(.callout)
            }
            if account.isPro {
                proSections
            } else {
                Section {
                    Text("sync.requiresPro").font(.callout)
                    Button("pro.discover") { showsPro = true }
                }
            }
        }
        .navigationTitle("sync.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { if account.isPro { await productivity.loadSync() } }
        .accountFailureAlert(account)
        .navigationDestination(isPresented: $showsPro) { ProView() }
        .sheet(isPresented: Binding(get: { recoveryCode != nil }, set: { if !$0 { recoveryCode = nil } })) {
            RecoveryCodeSheet(code: recoveryCode ?? "")
        }
    }

    @ViewBuilder private var proSections: some View {
        switch productivity.syncSnapshot?.status {
        case nil:
            Section { ProgressView() }
        case .notConfigured:
            Section {
                Button("sync.enable") { Task { await productivity.enableSync() } }
                    .accessibilityIdentifier("enableSync")
            } footer: {
                Text("sync.enable.footer")
            }
        case .pendingApproval:
            Section {
                Label("sync.pending", systemImage: "hourglass").font(.callout)
                Button("account.retry") { Task { await productivity.loadSync() } }
            }
            recoverySection
        case .ready:
            readySections
        }
    }

    private var recoverySection: some View {
        Section {
            TextField("sync.recovery.placeholder", text: $recoveryInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("recoveryInput")
            Button("sync.recovery.use") {
                let code = recoveryInput
                recoveryInput = ""
                Task { await productivity.recover(code: code) }
            }
            .disabled(recoveryInput.isEmpty)
        } header: {
            Text("sync.recovery.title")
        } footer: {
            Text("sync.recovery.footer")
        }
    }

    @ViewBuilder private var readySections: some View {
        Section {
            Label("sync.ready", systemImage: "checkmark.circle").foregroundStyle(.green)
            if let last = productivity.lastSync {
                Text(String(format: String(localized: "sync.report"), last.uploaded, last.downloaded))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if last.conflictsPreserved > 0 {
                    Text("sync.conflicts").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("sync.now") { Task { await productivity.syncNow() } }
                .disabled(productivity.isSyncing)
                .accessibilityIdentifier("syncNow")
        }
        if let devices = productivity.syncSnapshot?.devices.filter({ $0.status == .pendingApproval }), !devices.isEmpty {
            Section("sync.pendingDevices") {
                ForEach(devices) { device in
                    HStack {
                        Text(verbatim: device.displayName)
                        Spacer()
                        Button("sync.approve") { Task { await productivity.approve(device) } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        Section {
            Button("sync.recovery.create") {
                Task { recoveryCode = await productivity.createRecoveryCode() }
            }
            .accessibilityIdentifier("createRecovery")
        } footer: {
            Text("sync.recovery.create.footer")
        }
    }
}

/// Shown once: the code never reaches the settings, the journal or the server in clear.
private struct RecoveryCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let code: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button("home.copy") { UIPasteboard.general.string = code }
                } footer: {
                    Text("sync.recovery.warning")
                }
            }
            .navigationTitle("sync.recovery.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("common.done") { dismiss() }
            }
        }
    }
}
