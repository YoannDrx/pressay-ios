import Foundation
import Observation
import PressayAccount
import PressayShared

/// The Pro plans and purchases as the interface sees them. The rules live in `PurchaseCoordinator`;
/// this adds what the user is told, and only an action the user took ever asks them anything.
@MainActor
@Observable
final class StoreService {
    static let shared = StoreService()

    enum Notice: Equatable {
        /// Paid, but the cloud has not confirmed yet: Pro arrives at the next attempt.
        case awaitingConfirmation
        /// Waiting for someone to approve the purchase (Ask to Buy).
        case pendingApproval
        case nothingToRestore
        case restored
    }

    private(set) var plans: [StorePlan] = []
    private(set) var isLoadingPlans = false
    private(set) var plansFailed = false
    private(set) var isPurchasing = false
    var notice: Notice?
    /// A purchase the cloud cannot tie to this account without the user's word.
    var linkRequest: StoreTransactionRecord?

    @ObservationIgnored private let backend: any StoreBackend
    @ObservationIgnored private let coordinator: PurchaseCoordinator
    @ObservationIgnored private let account = AccountEnvironment.account
    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {
        #if DEBUG
        backend = FakeStoreBackend.current ?? StoreKitBackend()
        #else
        backend = StoreKitBackend()
        #endif
        coordinator = PurchaseCoordinator(account: AccountEnvironment.account, backend: backend, log: PressayLog.shared)
    }

    /// Starts listening as early as possible: a renewal or an approved purchase can arrive at any
    /// launch. Never presents anything to the user.
    func start() {
        guard updates == nil else { return }
        let stream = backend.updates()
        updates = Task(priority: .utility) { [weak self] in
            for await record in stream {
                await self?.handle(update: record)
            }
        }
        Task(priority: .utility) { await reconcile(force: false) }
    }

    func loadPlans() async {
        guard !isLoadingPlans else { return }
        isLoadingPlans = true
        plansFailed = false
        defer { isLoadingPlans = false }
        do {
            plans = try await backend.plans()
            plansFailed = plans.isEmpty
        } catch {
            plansFailed = true
            PressayLog.shared.event("store.productsFailed", ["error": ErrorTag.of(error)])
        }
    }

    // MARK: Purchase

    /// The account token ties the purchase to the Pressay account, so the Mac and the cloud
    /// recognize it without asking anything. The caller has signed in first.
    func purchase(_ plan: StorePlan) async {
        let snapshot = await account.cachedSnapshot()
        guard let accountID = snapshot.accountID, let token = UUID(uuidString: accountID) else {
            AccountModel.shared.failure = .notConnected
            return
        }
        isPurchasing = true
        notice = nil
        defer { isPurchasing = false }
        do {
            switch try await backend.purchase(productID: plan.id, accountToken: token) {
            case let .purchased(record):
                present(await coordinator.process(record))
                await refreshRights()
            case .pending:
                notice = .pendingApproval
                PressayLog.shared.event("store.pending")
            case .cancelled:
                PressayLog.shared.event("store.cancelled")
            }
        } catch {
            PressayLog.shared.event("store.purchaseFailed", ["error": ErrorTag.of(error)])
            AccountModel.shared.failure = CloudFailure("storekit_purchase_failed")
        }
    }

    // MARK: Restore

    /// The explicit Restore button: the only path that may ask for the Apple Account, and the
    /// only one that can lead to the question of linking a purchase.
    func restore() async {
        notice = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await backend.synchronize()
        } catch is StoreSyncCancelled {
            return
        } catch {
            PressayLog.shared.event("store.syncFailed", ["error": ErrorTag.of(error)])
        }
        let outcomes = await coordinator.reconcile(includingCurrent: true)
        outcomes.forEach(present)
        await refreshRights()
        if outcomes.isEmpty {
            notice = AccountModel.shared.isPro ? .restored : .nothingToRestore
        } else if outcomes.contains(.recorded) {
            notice = .restored
        }
    }

    /// Background delivery: never asks anything and never links.
    func reconcile(force: Bool) async {
        let outcomes = await coordinator.reconcile(includingCurrent: force)
        if outcomes.contains(.recorded) { await refreshRights() }
    }

    private func handle(update record: StoreTransactionRecord) async {
        // A renewal or a revocation needs the cloud's word; a signed-out user waits for a sign-in.
        guard await account.cachedSnapshot().connection == .connected else { return }
        if await coordinator.process(record) == .recorded { await refreshRights() }
    }

    /// The user confirmed that a purchase made elsewhere belongs to this account.
    func confirmLink(_ record: StoreTransactionRecord) async {
        linkRequest = nil
        isPurchasing = true
        defer { isPurchasing = false }
        let outcome = await coordinator.process(record, linkToAccount: true)
        present(outcome)
        if outcome == .recorded {
            notice = .restored
            await refreshRights()
        }
    }

    private func refreshRights() async {
        AccountModel.shared.apply(await account.cachedSnapshot())
    }

    private func present(_ outcome: PurchaseOutcome) {
        switch outcome {
        case .recorded, .ignored:
            break
        case let .needsLink(record):
            linkRequest = record
        case .awaitingConfirmation:
            notice = .awaitingConfirmation
        case let .rejected(code):
            AccountModel.shared.failure = CloudFailure(code)
        case .unverified:
            AccountModel.shared.failure = CloudFailure("storekit_unverified")
        }
    }
}
