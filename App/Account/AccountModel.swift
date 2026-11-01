import AuthenticationServices
import Foundation
import Observation
import PressayAccount
import PressayShared

/// The account as the interface sees it. Every call here is optional: a user who never signs in
/// never triggers one, and the app stays whole for everything free.
@MainActor
@Observable
final class AccountModel {
    static let shared = AccountModel()

    private(set) var snapshot: AccountSnapshot = .signedOut
    private(set) var devices: [AccountDevice] = []
    private(set) var revokedDevices: [RevokedDevice] = []
    private(set) var billing: BillingStatus?
    private(set) var isWorking = false
    /// A failure to show, as a code the interface turns into a sentence.
    var failure: CloudFailure?
    /// Shown once after the cloud accepted a deletion.
    var deletionRequested = false

    @ObservationIgnored private let service = AccountEnvironment.account
    @ObservationIgnored private var lastRefresh: Date?
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let installedKey = "account.installed"

    var isPro: Bool { snapshot.isPro }
    var isConnected: Bool { snapshot.connection == .connected }
    var isAppStoreSubscriber: Bool { snapshot.entitlement?.source == .appStore }

    private init() {}

    /// Reads what the Keychain proves, without the network.
    func start() async {
        if !UserDefaults.standard.bool(forKey: Self.installedKey) {
            // iOS keeps the Keychain across a reinstall: a fresh install starts signed out.
            await service.clearSessionAfterReinstall()
            UserDefaults.standard.set(true, forKey: Self.installedKey)
        }
        snapshot = await service.cachedSnapshot()
    }

    /// Called when the app comes to the foreground: a signed-out user causes no request.
    func refreshIfDue() async {
        snapshot = await service.cachedSnapshot()
        guard snapshot.connection != .signedOut else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        await refresh()
    }

    func refresh() async {
        lastRefresh = Date()
        do {
            snapshot = try await service.refresh()
        } catch {
            // Runs when the app comes to the front, not from a tap: the service journals the code,
            // and a stale alert must not wait for the next account screen.
            snapshot = await service.cachedSnapshot()
        }
    }

    func apply(_ snapshot: AccountSnapshot) {
        self.snapshot = snapshot
        lastRefresh = Date()
    }

    // MARK: Sign-in

    /// `authenticate` presents `ASWebAuthenticationSession` and returns the callback URL.
    func signIn(provider: SignInProvider?, authenticate: @MainActor (URL) async throws -> URL) async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        deletionRequested = false
        do {
            let request = try await service.beginSignIn(provider: provider)
            let callback = try await authenticate(request.url)
            apply(try await service.completeSignIn(request, callback: callback))
            PressayLog.shared.event("account.signedIn", ["connection": .tag(connectionTag)])
            await StoreService.shared.reconcile(force: false)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            PressayLog.shared.event("account.signInCancelled")
        } catch {
            report(error)
            snapshot = await service.cachedSnapshot()
        }
    }

    private var connectionTag: String {
        switch snapshot.connection {
        case .signedOut: "signedOut"
        case .awaitingDevice: "awaitingDevice"
        case .deviceLimitReached: "deviceLimit"
        case .deviceRevoked: "deviceRevoked"
        case .connected: "connected"
        }
    }

    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let failure = error as? CloudFailure ?? CloudFailure("cloud_request_failed")
        self.failure = failure
        PressayLog.shared.event("account.failed", ["code": .tag(failure.code)])
    }

    // MARK: Devices

    func loadRevokedDevices() async {
        do {
            revokedDevices = try await service.revokedDevices()
        } catch {
            report(error)
        }
    }

    /// Brings this iPhone back. The cloud refuses when three devices are already active, and the
    /// screen then offers to remove one.
    func restore(_ device: RevokedDevice) async {
        isWorking = true
        defer { isWorking = false }
        do {
            apply(try await service.restoreDevice(id: device.id))
            await StoreService.shared.reconcile(force: false)
        } catch let failure as CloudFailure where failure == .deviceLimitReached {
            await loadDevices()
            self.failure = failure
        } catch {
            report(error)
        }
    }

    func loadDevices() async {
        do {
            devices = try await service.devices()
        } catch {
            report(error)
        }
    }

    /// Frees a slot; if this iPhone was waiting for one, takes it at once.
    func remove(_ device: AccountDevice) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.removeDevice(id: device.id)
            if snapshot.connection != .connected {
                apply(try await service.connectDevice())
                await StoreService.shared.reconcile(force: false)
            }
            await loadDevices()
        } catch {
            report(error)
        }
    }

    func retryDevice() async {
        isWorking = true
        defer { isWorking = false }
        do {
            apply(try await service.connectDevice())
        } catch {
            report(error)
        }
    }

    // MARK: Billing

    func loadBilling() async {
        guard isConnected else { return }
        billing = try? await service.billingStatus()
    }

    // MARK: Leaving

    func signOut() async {
        await service.signOut()
        snapshot = await service.cachedSnapshot()
        devices = []
        billing = nil
        lastRefresh = nil
        PressayLog.shared.event("account.signedOut")
    }

    /// Answers true when an App Store subscription needs the user's explicit choice first.
    func deleteAccount(acknowledgingAppleSubscription acknowledging: Bool) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            let deleted = try await service.deleteAccount(acknowledgingAppleSubscription: acknowledging)
            if let deleted {
                await AccountEnvironment.sync.forget(accountID: deleted)
            }
            snapshot = await service.cachedSnapshot()
            devices = []
            billing = nil
            lastRefresh = nil
            deletionRequested = true
            return false
        } catch let failure as CloudFailure where failure == .appleSubscriptionActive {
            return true
        } catch {
            report(error)
            return false
        }
    }
}
