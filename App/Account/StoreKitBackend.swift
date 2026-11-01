import Foundation
import PressayAccount
import StoreKit
import UIKit

/// The real store. Holds on to the transactions it hands out, to finish them once the cloud
/// recorded them.
actor StoreKitBackend: StoreBackend {
    private var transactions: [UInt64: Transaction] = [:]

    func plans() async throws -> [StorePlan] {
        let products = try await Product.products(for: ProductCatalog.all)
        var plans: [StorePlan] = []
        for id in ProductCatalog.all {
            guard let product = products.first(where: { $0.id == id }) else { continue }
            let eligible = await product.subscription?.isEligibleForIntroOffer ?? false
            plans.append(StorePlan(
                id: product.id,
                displayName: product.displayName,
                priceLine: StorePrice.line(for: product),
                trialLine: eligible ? StorePrice.trial(for: product) : nil
            ))
        }
        return plans
    }

    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw CloudFailure("storekit_product_unavailable")
        }
        let scene = await Self.activeScene()
        guard let scene else { throw CloudFailure("storekit_window_unavailable") }
        let result = try await product.purchase(confirmIn: scene, options: [.appAccountToken(accountToken)])
        switch result {
        case let .success(verification): return .purchased(record(verification))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .cancelled
        }
    }

    func synchronize() async throws {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            throw StoreSyncCancelled()
        }
    }

    func unfinished() async -> [StoreTransactionRecord] {
        var records: [StoreTransactionRecord] = []
        for await result in Transaction.unfinished {
            records.append(record(result))
        }
        return records
    }

    func current() async -> [StoreTransactionRecord] {
        var records: [StoreTransactionRecord] = []
        for await result in Transaction.currentEntitlements {
            records.append(record(result))
        }
        return records
    }

    func finish(_ transactionID: UInt64) async {
        await transactions[transactionID]?.finish()
        transactions[transactionID] = nil
    }

    nonisolated func updates() -> AsyncStream<StoreTransactionRecord> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    continuation.yield(await self.record(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ result: VerificationResult<Transaction>) -> StoreTransactionRecord {
        switch result {
        case let .verified(transaction):
            transactions[transaction.id] = transaction
            return StoreTransactionRecord(
                id: transaction.id,
                productID: transaction.productID,
                signedTransaction: result.jwsRepresentation,
                isVerified: true,
                environment: transaction.environment.rawValue
            )
        case let .unverified(transaction, _):
            return StoreTransactionRecord(
                id: transaction.id,
                productID: transaction.productID,
                signedTransaction: "",
                isVerified: false,
                environment: transaction.environment.rawValue
            )
        }
    }

    @MainActor
    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        return scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene ?? scenes.first as? UIWindowScene
    }
}

/// Price and period, always StoreKit's: App Review 3.1.2 wants the period next to the price.
enum StorePrice {
    static func line(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        return String(
            format: String(localized: "pro.price.period"),
            product.displayPrice,
            period.unit.formatted(product.subscriptionPeriodUnitFormatStyle)
        )
    }

    static func trial(for product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial,
              let period = product.subscription?.subscriptionPeriod
        else { return nil }
        return String(
            format: String(localized: "pro.trial.line"),
            offer.period.formatted(product.subscriptionPeriodFormatStyle),
            product.displayPrice,
            period.unit.formatted(product.subscriptionPeriodUnitFormatStyle)
        )
    }
}

#if DEBUG
/// `-PressayFakeStore 1` replaces StoreKit in a debug run, with the local fake cloud: the iOS 26.3
/// simulator cannot start a `.storekit` session outside Xcode (Apple bug FB22237318). These "prices"
/// are test labels; the real ones only ever come from StoreKit. `-PressayFakeStore foreign` holds a
/// purchase made outside this account, to exercise linking.
actor FakeStoreBackend: StoreBackend {
    private let holdsForeignPurchase: Bool
    private var purchased: [StoreTransactionRecord] = []
    private var finished = Set<UInt64>()
    private var nextID: UInt64 = 2_000_000_000

    init(holdsForeignPurchase: Bool) {
        self.holdsForeignPurchase = holdsForeignPurchase
    }

    static var current: FakeStoreBackend? {
        let value = ProcessInfo.processInfo.environment["PressayFakeStore"] ?? UserDefaults.standard.string(forKey: "PressayFakeStore")
        return value.map { FakeStoreBackend(holdsForeignPurchase: $0 == "foreign") }
    }

    func plans() async throws -> [StorePlan] {
        [
            StorePlan(id: ProductCatalog.annual, displayName: "TEST annual", priceLine: "TEST / year", trialLine: "TEST free trial"),
            StorePlan(id: ProductCatalog.monthly, displayName: "TEST monthly", priceLine: "TEST / month", trialLine: nil),
        ]
    }

    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseResult {
        let record = makeRecord(productID: productID, token: accountToken.uuidString.lowercased())
        purchased.append(record)
        return .purchased(record)
    }

    func synchronize() async throws {}

    func unfinished() async -> [StoreTransactionRecord] {
        purchased.filter { !finished.contains($0.id) }
    }

    func current() async -> [StoreTransactionRecord] {
        if holdsForeignPurchase, purchased.isEmpty {
            purchased.append(makeRecord(productID: ProductCatalog.annual, token: UUID().uuidString.lowercased()))
        }
        return purchased
    }

    func finish(_ transactionID: UInt64) async {
        finished.insert(transactionID)
    }

    nonisolated func updates() -> AsyncStream<StoreTransactionRecord> {
        AsyncStream { _ in }
    }

    private func makeRecord(productID: String, token: String) -> StoreTransactionRecord {
        nextID += 1
        let encode: (String) -> String = { value in
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = #"{"productId":"\#(productID)","appAccountToken":"\#(token)","padding":"0000000000000000"}"#
        return StoreTransactionRecord(
            id: nextID,
            productID: productID,
            signedTransaction: "\(encode(#"{"alg":"ES256"}"#)).\(encode(payload)).fake-signature",
            isVerified: true,
            environment: "Xcode"
        )
    }
}
#endif
