import PressayAccount
import StoreKit
import SwiftUI

/// Pressay Pro: what it adds, its plans at the prices StoreKit gives, and the required disclosures.
/// Nothing here leads to a purchase outside the App Store (App Review 3.1.1).
struct ProView: View {
    @Environment(AccountModel.self) private var account
    @Environment(StoreService.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if account.isPro {
                    ProStatusCard()
                } else {
                    ProHero()
                    ProFeatureList()
                    PlanPicker()
                }
                RestoreFooter()
                LegalFooter()
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("pro.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadPlans() }
        .accountFailureAlert(account)
        .alert("pro.link.title", isPresented: linkBinding, presenting: store.linkRequest) { request in
            Button("pro.link.confirm") { Task { await store.confirmLink(request) } }
            Button("common.cancel", role: .cancel) { store.linkRequest = nil }
        } message: { _ in
            Text("pro.link.body")
        }
    }

    private var linkBinding: Binding<Bool> {
        Binding(get: { store.linkRequest != nil }, set: { if !$0 { store.linkRequest = nil } })
    }
}

private struct ProHero: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("pro.headline")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("pro.subheadline")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
}

/// Only what ships in this version: a feature that is not here does not get sold.
private struct ProFeatureList: View {
    private let features: [(LocalizedStringKey, String)] = [
        ("pro.feature.modes", "wand.and.sparkles"),
        ("pro.feature.history", "clock.arrow.circlepath"),
        ("pro.feature.dictionary", "character.book.closed"),
        ("pro.feature.sync", "lock.icloud"),
        ("pro.feature.devices", "laptopcomputer.and.iphone"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(features.indices, id: \.self) { index in
                Label(features[index].0, systemImage: features[index].1)
                    .font(.callout)
            }
            Divider()
            Label("pro.feature.free", systemImage: "mic.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct PlanPicker: View {
    @Environment(AccountModel.self) private var account
    @Environment(StoreService.self) private var store
    @State private var selection = ProductCatalog.annual
    @State private var signsIn = false
    @State private var pendingPlan: StorePlan?

    private var selected: StorePlan? { store.plans.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 12) {
            if store.plans.isEmpty {
                if store.plansFailed {
                    Text("pro.products.failed").font(.callout).foregroundStyle(.secondary)
                    Button("account.retry") { Task { await store.loadPlans() } }
                } else {
                    ProgressView()
                }
            }
            ForEach(store.plans) { plan in
                PlanCard(plan: plan, isSelected: plan.id == selection) {
                    selection = plan.id
                }
            }
            if let selected {
                Button {
                    buy(selected)
                } label: {
                    Group {
                        if store.isPurchasing {
                            ProgressView()
                        } else if selected.trialLine != nil {
                            Text("pro.subscribe.trial")
                        } else {
                            Text("pro.subscribe")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isPurchasing)
                .accessibilityIdentifier("subscribe")

                if !account.isConnected {
                    Text("pro.signInFirst").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .sheet(isPresented: $signsIn) {
            NavigationStack {
                AccountView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.cancel") { signsIn = false }
                        }
                    }
            }
        }
        // The account appeared while the sheet was up: carry on with the purchase that asked for it.
        .onChange(of: account.isConnected) { _, connected in
            guard connected, let pendingPlan else { return }
            self.pendingPlan = nil
            signsIn = false
            Task { await store.purchase(pendingPlan) }
        }
    }

    private func buy(_ plan: StorePlan) {
        if account.isConnected {
            Task { await store.purchase(plan) }
        } else {
            pendingPlan = plan
            signsIn = true
        }
    }
}

private struct PlanCard: View {
    let plan: StorePlan
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: plan.displayName).font(.headline)
                    Text(verbatim: plan.priceLine).font(.callout)
                    if let trial = plan.trialLine {
                        Text(verbatim: trial).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("plan-\(plan.id)")
    }
}

/// Where Pro comes from. Only an App Store subscription links to its management: a subscription
/// made elsewhere is simply recognized (App Review 3.1.3(b)), with no way out of the app.
private struct ProStatusCard: View {
    @Environment(AccountModel.self) private var account
    @State private var managesSubscriptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("pro.status.title", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if account.billing?.status == "trialing" {
                Text("pro.status.trial").font(.callout)
            }
            Text(sourceKey).font(.callout).foregroundStyle(.secondary)
            if let end = account.billing?.periodEnd {
                Text(String(
                    format: String(localized: account.billing?.cancelAtPeriodEnd == true ? "pro.status.endsOn" : "pro.status.renewsOn"),
                    end.formatted(date: .long, time: .omitted)
                ))
                .font(.callout)
            }
            if account.isAppStoreSubscriber {
                Button("pro.manage") { managesSubscriptions = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("manageSubscription")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
        .manageSubscriptionsSheet(isPresented: $managesSubscriptions)
        .task { await account.loadBilling() }
    }

    private var sourceKey: LocalizedStringKey {
        switch account.snapshot.entitlement?.source {
        case .appStore: "pro.source.appStore"
        case .stripe: "pro.source.account"
        case .support: "pro.source.offered"
        case .trial: "pro.source.trial"
        default: "pro.source.account"
        }
    }
}

private struct RestoreFooter: View {
    @Environment(AccountModel.self) private var account
    @Environment(StoreService.self) private var store
    @State private var signsIn = false

    var body: some View {
        VStack(spacing: 8) {
            if let notice = store.notice {
                Text(message(for: notice))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("storeNotice")
            }
            Button("pro.restore") {
                if account.isConnected {
                    Task { await store.restore() }
                } else {
                    signsIn = true
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isPurchasing)
            .accessibilityIdentifier("restorePurchases")
        }
        .sheet(isPresented: $signsIn) {
            NavigationStack {
                AccountView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.cancel") { signsIn = false }
                        }
                    }
            }
        }
        .onChange(of: account.isConnected) { _, connected in
            guard connected, signsIn else { return }
            signsIn = false
            Task { await store.restore() }
        }
    }

    private func message(for notice: StoreService.Notice) -> LocalizedStringKey {
        switch notice {
        case .awaitingConfirmation: "pro.notice.awaitingConfirmation"
        case .pendingApproval: "pro.notice.pendingApproval"
        case .nothingToRestore: "pro.notice.nothingToRestore"
        case .restored: "pro.notice.restored"
        }
    }
}

/// App Review 3.1.2: the renewal terms and working links to the Terms and the Privacy Policy.
private struct LegalFooter: View {
    private var language: String {
        Locale.preferredLanguages.first?.hasPrefix("fr") == true ? "fr" : "en"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("pro.legal")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                if let terms = URL(string: "https://press-say.app/\(language)/terms") {
                    Link("pro.terms", destination: terms)
                        .accessibilityIdentifier("termsLink")
                }
                if let privacy = URL(string: "https://press-say.app/\(language)/privacy") {
                    Link("pro.privacy", destination: privacy)
                        .accessibilityIdentifier("privacyLink")
                }
            }
            .font(.caption)
        }
    }
}
