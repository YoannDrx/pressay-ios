import PressayAccount
import StoreKit
import StoreKitTest
import XCTest
@testable import Pressay

/// Purchases through StoreKit's local test session, inside the app, against the local fake cloud
/// (`scripts/fake-cloud.mjs`). Run with the environment of the fake server:
///
///   PressayCloudURL, PressayEntitlementKey, PressayEntitlementKeyID (TEST_RUNNER_ prefix for xcodebuild)
///
/// Without it the tests skip: CI builds this bundle but does not run a simulator. Under `xcodebuild`
/// on iOS 26.3 and later simulators, `SKTestSession` fails with SKInternalErrorDomain 3 and asks
/// for a real Apple Account (Apple bug FB22237318): use a 26.2 runtime, or run from Xcode.
final class StoreFlowTests: XCTestCase {
    private var session: SKTestSession?

    @MainActor
    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["PressayCloudURL"] == nil, "needs the local fake cloud")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Pressay", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        session.resetToDefaultState()
        self.session = session
    }

    /// Prices and trial as StoreKit gives them, never from the code.
    @MainActor
    func testProductsComeFromStoreKitWithTheAnnualTrial() async throws {
        let store = StoreService.shared
        await store.loadPlans()
        XCTAssertEqual(Set(store.plans.map(\.id)), Set(ProductCatalog.all))
        let annual = try XCTUnwrap(store.plans.first { $0.id == ProductCatalog.annual })
        XCTAssertFalse(annual.priceLine.isEmpty)
        XCTAssertNotNil(annual.trialLine)
        XCTAssertNil(try XCTUnwrap(store.plans.first { $0.id == ProductCatalog.monthly }).trialLine)
    }

    /// Buy with the account token, hand the JWS to the cloud, finish, and see Pro verified locally.
    /// Then restoration, which re-delivers the same purchase.
    @MainActor
    func testPurchaseThenRestoreGivesProThroughTheCloud() async throws {
        let account = AccountEnvironment.account
        await account.clearSessionAfterReinstall()
        let request = try await account.beginSignIn(provider: .apple)
        let state = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value)
        let callback = try XCTUnwrap(URL(string: "pressay://oauth/callback?code=fake&state=\(state)"))
        let signedIn = try await account.completeSignIn(request, callback: callback)
        AccountModel.shared.apply(signedIn)
        XCTAssertEqual(signedIn.connection, .connected)

        let store = StoreService.shared
        await store.loadPlans()
        let annual = try XCTUnwrap(store.plans.first { $0.id == ProductCatalog.annual })
        await store.purchase(annual)
        XCTAssertNil(AccountModel.shared.failure, AccountModel.shared.failure?.code ?? "")

        let afterPurchase = await account.cachedSnapshot()
        XCTAssertTrue(afterPurchase.isPro)
        XCTAssertEqual(afterPurchase.entitlement?.source, .appStore)
        for await unfinished in Transaction.unfinished {
            XCTFail("a recorded transaction stays unfinished: \(unfinished.jwsRepresentation.count)")
        }

        let current = await currentProductIDs()
        XCTAssertEqual(current, [ProductCatalog.annual])

        await store.restore()
        XCTAssertEqual(store.notice, .restored)
    }

    /// Hold the app open so the simulator can walk through the screens with `.storekit` products.
    /// Only with TEST_RUNNER_PressayHoldSeconds set.
    @MainActor
    func testHoldForManualWalkthrough() async throws {
        let seconds = try XCTUnwrap(Double(ProcessInfo.processInfo.environment["PressayHoldSeconds"] ?? "0"))
        try XCTSkipIf(seconds <= 0, "only for a manual walkthrough")
        session?.disableDialogs = false
        try await Task.sleep(for: .seconds(seconds))
    }

    @MainActor
    private func currentProductIDs() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result { ids.append(transaction.productID) }
        }
        return ids
    }
}
