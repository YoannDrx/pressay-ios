import Foundation
import PressayShared

/// A subscription as the paywall shows it. Every string comes from the store, never from the code.
public struct StorePlan: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let priceLine: String
    /// Set only when this Apple Account is eligible for the free trial.
    public let trialLine: String?

    public init(id: String, displayName: String, priceLine: String, trialLine: String?) {
        self.id = id
        self.displayName = displayName
        self.priceLine = priceLine
        self.trialLine = trialLine
    }
}

/// A transaction as StoreKit delivers it. An unverified one is never sent to the cloud.
public struct StoreTransactionRecord: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let productID: String
    public let signedTransaction: String
    public let isVerified: Bool
    public let environment: String

    public init(id: UInt64, productID: String, signedTransaction: String, isVerified: Bool, environment: String) {
        self.id = id
        self.productID = productID
        self.signedTransaction = signedTransaction
        self.isVerified = isVerified
        self.environment = environment
    }
}

public enum StorePurchaseResult: Equatable, Sendable {
    case purchased(StoreTransactionRecord)
    /// Waiting for someone to approve it (Ask to Buy).
    case pending
    case cancelled
}

public struct StoreSyncCancelled: Error {
    public init() {}
}

/// StoreKit behind an interface: `StoreKitBackend` in the app, a stand-in in tests.
public protocol StoreBackend: Sendable {
    func plans() async throws -> [StorePlan]
    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseResult
    /// `AppStore.sync()`: may ask for the Apple Account, so only an explicit Restore calls it.
    func synchronize() async throws
    func unfinished() async -> [StoreTransactionRecord]
    func current() async -> [StoreTransactionRecord]
    func finish(_ transactionID: UInt64) async
    func updates() -> AsyncStream<StoreTransactionRecord>
}

/// What became of a transaction.
public enum PurchaseOutcome: Equatable, Sendable {
    /// The cloud recorded it, and it was finished.
    case recorded
    /// The user must confirm that it belongs to this account.
    case needsLink(StoreTransactionRecord)
    /// Kept unfinished: StoreKit delivers it again, and the next launch retries.
    case awaitingConfirmation
    case rejected(String)
    case unverified
    /// Not one of the Pro products.
    case ignored
}

/// The rule behind every purchase: a transaction is finished only once the cloud recorded it. Until
/// then StoreKit keeps it, so a purchase cannot be lost to a network failure.
public struct PurchaseCoordinator: Sendable {
    private let account: AccountService
    private let backend: any StoreBackend
    private let log: PressayLog?

    public init(account: AccountService, backend: any StoreBackend, log: PressayLog? = nil) {
        self.account = account
        self.backend = backend
        self.log = log
    }

    public func process(_ record: StoreTransactionRecord, linkToAccount: Bool = false) async -> PurchaseOutcome {
        guard record.isVerified else {
            log?.event("store.unverified")
            return .unverified
        }
        guard ProductCatalog.isKnown(record.productID) else { return .ignored }
        var failure: CloudFailure?
        do {
            _ = try await account.deliver(
                signedTransaction: record.signedTransaction, transactionID: record.id, linkToAccount: linkToAccount
            )
        } catch {
            failure = error as? CloudFailure ?? CloudFailure("cloud_request_failed")
        }
        log?.event("store.delivered", ["outcome": .tag(failure?.code ?? "recorded"), "environment": .tag(record.environment)])
        switch TransactionDecision.after(failure) {
        case .finish:
            await backend.finish(record.id)
            return .recorded
        case .askToLink:
            return .needsLink(record)
        case .retryLater:
            return .awaitingConfirmation
        case let .rejected(code):
            return .rejected(code)
        }
    }

    /// Delivers what StoreKit holds. Without an account nothing leaves: it waits for a sign-in.
    /// Current subscriptions are read only when the signed rights do not already say Pro, or when
    /// the user asked to restore.
    public func reconcile(includingCurrent force: Bool) async -> [PurchaseOutcome] {
        let snapshot = await account.cachedSnapshot()
        guard snapshot.connection == .connected else { return [] }
        var outcomes: [PurchaseOutcome] = []
        var seen = Set<UInt64>()
        for record in await backend.unfinished() where seen.insert(record.id).inserted {
            outcomes.append(await process(record))
        }
        guard force || !snapshot.isPro else { return outcomes }
        for record in await backend.current() where seen.insert(record.id).inserted {
            outcomes.append(await process(record))
        }
        return outcomes
    }
}
