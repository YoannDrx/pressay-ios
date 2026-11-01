import PressayAccount
import SwiftUI

/// Which mode finishes each dictation. Runs on the device; when it cannot, the dictated text is
/// inserted as is.
struct ModesView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ProductivityModel.self) private var productivity
    @State private var showsPro = false

    #if PRESSAY_SYNC
    private var customModes: [PressayMode] { productivity.document.modes.filter { !$0.isBuiltin } }
    #endif

    var body: some View {
        List {
            Section {
                AvailabilityNote()
                if !account.isPro {
                    if productivity.trialsRemaining > 0 {
                        Text(String(format: String(localized: "modes.trials"), productivity.trialsRemaining))
                            .font(.callout)
                    } else {
                        Text("modes.trials.none").font(.callout)
                    }
                    Button("pro.discover") { showsPro = true }
                        .accessibilityIdentifier("modesUpgrade")
                }
            } footer: {
                Text("modes.footer")
            }
            Section {
                ForEach(PressayMode.builtin) { mode in
                    let nameKey = "mode.\(mode.id).name"
                    let detailKey = "mode.\(mode.id).description"
                    ModeRow(name: Text(LocalizedStringKey(nameKey)), detail: Text(LocalizedStringKey(detailKey)), id: mode.id)
                }
            }
            #if PRESSAY_SYNC
            if !customModes.isEmpty {
                Section("modes.custom") {
                    ForEach(customModes) { mode in
                        ModeRow(
                            name: Text(verbatim: mode.customName ?? ""),
                            detail: Text(verbatim: mode.customDescription ?? ""),
                            id: mode.id
                        )
                    }
                }
            }
            #endif
        }
        .navigationTitle("modes.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsPro) { ProView() }
    }
}

private struct ModeRow: View {
    @Environment(ProductivityModel.self) private var productivity
    let name: Text
    let detail: Text
    let id: String

    var body: some View {
        Button {
            productivity.selectMode(id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    name
                    detail.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if productivity.document.activeMode.id == id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(productivity.document.activeMode.id == id ? .isSelected : [])
        .accessibilityIdentifier("mode-\(id)")
    }
}

private struct AvailabilityNote: View {
    var body: some View {
        switch ModelAvailability.current {
        case .available:
            Label("modes.available", systemImage: "checkmark.circle").font(.callout)
        case .deviceNotEligible:
            Label("modes.unavailable.device", systemImage: "info.circle").font(.callout)
        case .appleIntelligenceOff:
            Label("modes.unavailable.off", systemImage: "info.circle").font(.callout)
        case .notReady:
            Label("modes.unavailable.notReady", systemImage: "arrow.down.circle").font(.callout)
        case .unknown:
            Label("modes.unavailable.other", systemImage: "info.circle").font(.callout)
        }
    }
}
