import Foundation
import Testing
@testable import PressayAccount

/// StoreKit's side of a purchase, scripted.
private actor FakeBackend: StoreBackend {
    var unfinishedRecords: [StoreTransactionRecord] = []
    var currentRecords: [StoreTransactionRecord] = []
    var finished: [UInt64] = []

    func set(unfinished: [StoreTransactionRecord] = [], current: [StoreTransactionRecord] = []) {
        unfinishedRecords = unfinished
        currentRecords = current
    }

    func plans() async throws -> [StorePlan] { [] }
    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseResult { .cancelled }
    func synchronize() async throws {}
    func unfinished() async -> [StoreTransactionRecord] { unfinishedRecords }
    func current() async -> [StoreTransactionRecord] { currentRecords }
    func finish(_ transactionID: UInt64) async { finished.append(transactionID) }
    nonisolated func updates() -> AsyncStream<StoreTransactionRecord> { AsyncStream { _ in } }
}

@Suite struct PurchaseCoordinatorTests {
    let cloud = FakeCloud()
    private let backend = FakeBackend()

    func record(_ id: UInt64 = 1, product: String = ProductCatalog.annual, verified: Bool = true) -> StoreTransactionRecord {
        let signed = String(repeating: "a", count: 40) + "." + String(repeating: "b", count: 40) + ".sig"
        return StoreTransactionRecord(id: id, productID: product, signedTransaction: signed, isVerified: verified, environment: "Xcode")
    }

    func coordinator() async throws -> (PurchaseCoordinator, AccountService) {
        let account = try cloud.service()
        _ = try await cloud.signIn(account)
        return (PurchaseCoordinator(account: account, backend: backend), account)
    }

    @Test func aRecordedPurchaseIsFinishedAndGivesPro() async throws {
        let (coordinator, account) = try await coordinator()
        #expect(await coordinator.process(record()) == .recorded)
        #expect(await backend.finished == [1])
        #expect(await account.cachedSnapshot().isPro)
    }

    @Test func aPurchaseTheCloudDidNotConfirmStaysUnfinished() async throws {
        let (coordinator, account) = try await coordinator()
        cloud.update { $0.offline = true }
        #expect(await coordinator.process(record()) == .awaitingConfirmation)
        #expect(await backend.finished.isEmpty)
        cloud.update { $0.offline = false; $0.restoreFailure = (503, "app_store_status_unavailable") }
        #expect(await coordinator.process(record()) == .awaitingConfirmation)
        #expect(await backend.finished.isEmpty)
        #expect(await account.cachedSnapshot().isPro == false)
        // The next attempt succeeds, and only then the transaction is finished.
        cloud.update { $0.restoreFailure = nil }
        await backend.set(unfinished: [record()])
        #expect(await coordinator.reconcile(includingCurrent: false) == [.recorded])
        #expect(await backend.finished == [1])
    }

    @Test func aForeignPurchaseAsksForALinkThenLinks() async throws {
        let (coordinator, _) = try await coordinator()
        cloud.update { $0.restoreFailure = (403, "app_store_account_mismatch") }
        let foreign = record()
        #expect(await coordinator.process(foreign) == .needsLink(foreign))
        #expect(await backend.finished.isEmpty)
        cloud.update { $0.restoreFailure = nil }
        #expect(await coordinator.process(foreign, linkToAccount: true) == .recorded)
        let last = try #require(cloud.transport.requests.last { $0.url?.path() == "/v1/billing/restore-app-store" })
        #expect(String(bytes: last.httpBody ?? Data(), encoding: .utf8)?.contains(#""linkToCurrentAccount":true"#) == true)
    }

    @Test(arguments: ["app_store_sandbox_not_allowed", "app_store_purchase_already_linked", "apple_customer_conflict"])
    func aRefusedPurchaseGivesNoProAndSaysWhy(code: String) async throws {
        let (coordinator, account) = try await coordinator()
        cloud.update { $0.restoreFailure = (403, code) }
        #expect(await coordinator.process(record()) == .rejected(code))
        #expect(await backend.finished.isEmpty)
        #expect(await account.cachedSnapshot().isPro == false)
    }

    @Test func anUnverifiedOrUnknownTransactionNeverLeaves() async throws {
        let (coordinator, _) = try await coordinator()
        #expect(await coordinator.process(record(verified: false)) == .unverified)
        #expect(await coordinator.process(record(product: "something.else")) == .ignored)
        #expect(!cloud.transport.paths().contains("POST /v1/billing/restore-app-store"))
    }

    @Test func nothingLeavesWithoutAnAccount() async throws {
        let account = try cloud.service()
        await backend.set(unfinished: [record()], current: [record(2)])
        let coordinator = PurchaseCoordinator(account: account, backend: backend)
        #expect(await coordinator.reconcile(includingCurrent: true).isEmpty)
        #expect(cloud.transport.requests.isEmpty)
    }

    @Test func currentSubscriptionsAreReadOnlyWhenTheyCanChangeSomething() async throws {
        let (coordinator, _) = try await coordinator()
        await backend.set(current: [record(5)])
        // Free: a subscription this Apple Account already holds gets delivered.
        #expect(await coordinator.reconcile(includingCurrent: false) == [.recorded])
        // Already Pro: nothing to ask the cloud at each launch, unless the user asks to restore.
        let before = cloud.transport.requests.count
        #expect(await coordinator.reconcile(includingCurrent: false).isEmpty)
        #expect(cloud.transport.requests.count == before)
        #expect(await coordinator.reconcile(includingCurrent: true) == [.recorded])
    }
}
