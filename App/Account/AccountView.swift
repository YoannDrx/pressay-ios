import PressayAccount
import StoreKit
import SwiftUI

/// The optional account: sign-in, the three device slots, sign-out and deletion.
struct AccountView: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        Form {
            switch account.snapshot.connection {
            case .signedOut:
                SignedOutSection()
            case .awaitingDevice:
                AwaitingDeviceSection()
            case .deviceLimitReached:
                DeviceLimitSection()
            case .deviceRevoked:
                DeviceRevokedSection()
            case .connected:
                ConnectedSections()
            }
            if account.deletionRequested {
                Section {
                    Label("account.delete.done", systemImage: "checkmark.circle")
                }
            }
        }
        .navigationTitle("account.title")
        .navigationBarTitleDisplayMode(.inline)
        .accountFailureAlert(account)
        .overlay {
            if account.isWorking {
                ProgressView()
            }
        }
    }
}

private struct SignedOutSection: View {
    var body: some View {
        Section {
            SignInButtons()
                .padding(.vertical, 6)
        } header: {
            Text("account.signIn.title")
        } footer: {
            Text("account.signIn.footer")
        }
    }
}

private struct AwaitingDeviceSection: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        Section {
            Text("account.awaitingDevice")
            Button("account.retry") { Task { await account.retryDevice() } }
                .accessibilityIdentifier("retryDevice")
            Button("account.signOut", role: .destructive) { Task { await account.signOut() } }
        }
    }
}

/// The fourth device: the session is fine, there is just no slot left. Everything free keeps
/// working; freeing a slot takes one tap, from here.
private struct DeviceLimitSection: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        Section {
            Label("account.deviceLimit.title", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("account.deviceLimit.body")
                .font(.callout)
        }
        Section("account.devices") {
            DeviceRows()
        }
        Section {
            Button("account.retry") { Task { await account.retryDevice() } }
            Button("account.signOut", role: .destructive) { Task { await account.signOut() } }
        }
    }
}

/// This iPhone was removed from the account, from here or elsewhere. The cloud refuses it until
/// its owner brings it back: nothing happens without this tap.
private struct DeviceRevokedSection: View {
    @Environment(AccountModel.self) private var account

    private var thisIPhone: RevokedDevice? { account.revokedDevices.first(where: \.isThisIPhone) }

    /// A reinstall forgets which row is this iPhone: the iPhones of the account are then offered.
    private var candidates: [RevokedDevice] {
        thisIPhone.map { [$0] } ?? account.revokedDevices.filter { $0.device.platform == "ios" }
    }

    var body: some View {
        Section {
            Label("account.deviceRevoked.title", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("account.deviceRevoked.body")
                .font(.callout)
        }
        Section {
            ForEach(candidates) { candidate in
                Button {
                    Task { await account.restore(candidate) }
                } label: {
                    Label {
                        if candidate.isThisIPhone {
                            Text("account.deviceRevoked.restore")
                        } else {
                            Text(verbatim: candidate.device.displayName)
                        }
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                .accessibilityIdentifier("restoreDevice")
            }
            if candidates.isEmpty {
                Button("account.retry") { Task { await account.retryDevice() } }
            }
        }
        if !account.devices.isEmpty {
            Section("account.devices") {
                DeviceRows()
            }
        }
        Section {
            Button("account.signOut", role: .destructive) { Task { await account.signOut() } }
        }
        .task { await account.loadRevokedDevices() }
    }
}

struct DeviceRows: View {
    @Environment(AccountModel.self) private var account
    @State private var candidate: AccountDevice?

    var body: some View {
        Group {
            if account.devices.isEmpty {
                Text("account.devices.empty").foregroundStyle(.secondary)
            }
            ForEach(account.devices) { device in
                let isCurrent = device.id == account.snapshot.deviceID
                HStack {
                    Image(systemName: device.platform == "ios" ? "iphone" : device.platform == "windows" ? "pc" : "laptopcomputer")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(verbatim: device.displayName)
                        if isCurrent {
                            Text("account.devices.current").font(.caption).foregroundStyle(.secondary)
                        } else if let seen = device.lastSeen {
                            Text(seen, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !isCurrent {
                        Button("account.devices.remove", role: .destructive) { candidate = device }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("removeDevice")
                    }
                }
            }
        }
        .task { await account.loadDevices() }
        .confirmationDialog(
            "account.devices.remove.confirm",
            isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }),
            titleVisibility: .visible,
            presenting: candidate
        ) { device in
            Button("account.devices.remove", role: .destructive) {
                Task { await account.remove(device) }
            }
        }
    }
}

private struct ConnectedSections: View {
    @Environment(AccountModel.self) private var account
    @State private var confirmsDeletion = false
    @State private var asksAboutSubscription = false
    @State private var managesSubscriptions = false

    var body: some View {
        Section {
            if let email = account.snapshot.email {
                LabeledContent("account.email") { Text(verbatim: email) }
            }
            NavigationLink {
                ProView()
            } label: {
                LabeledContent("pro.title") {
                    Text(account.isPro ? "pro.status.active" : "pro.status.free")
                }
            }
            if account.snapshot.sessionExpired {
                Label("account.sessionExpired", systemImage: "exclamationmark.circle")
                    .font(.callout)
                SignInButtons()
            }
        }

        Section {
            DeviceRows()
        } header: {
            Text("account.devices")
        } footer: {
            Text("account.devices.footer")
        }

        #if PRESSAY_SYNC
        Section {
            NavigationLink {
                SyncView()
            } label: {
                Label("sync.title", systemImage: "lock.icloud")
            }
            .accessibilityIdentifier("syncSettings")
        }
        #endif

        Section {
            Button("account.signOut") { Task { await account.signOut() } }
                .accessibilityIdentifier("signOut")
            Button("account.delete", role: .destructive) { confirmsDeletion = true }
                .accessibilityIdentifier("deleteAccount")
        } footer: {
            Text("account.delete.footer")
        }
        .confirmationDialog("account.delete.confirm.title", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("account.delete.confirm.action", role: .destructive) {
                Task { await delete(acknowledging: false) }
            }
        } message: {
            Text("account.delete.confirm.body")
        }
        // Deleting the account does not cancel what Apple bills: the user chooses knowingly.
        .confirmationDialog("account.delete.apple.title", isPresented: $asksAboutSubscription, titleVisibility: .visible) {
            Button("account.delete.apple.manage") { managesSubscriptions = true }
            Button("account.delete.apple.anyway", role: .destructive) {
                Task { await delete(acknowledging: true) }
            }
        } message: {
            Text("account.delete.apple.body")
        }
        .manageSubscriptionsSheet(isPresented: $managesSubscriptions)
    }

    private func delete(acknowledging: Bool) async {
        asksAboutSubscription = await account.deleteAccount(acknowledgingAppleSubscription: acknowledging)
    }
}
