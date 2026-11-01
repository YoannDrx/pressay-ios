import Foundation

/// A failure of the account layer: a short code, never a server message, a token or an address.
/// Safe to show in the journal.
public struct CloudFailure: Error, Equatable, Sendable {
    public let code: String

    public init(_ code: String) {
        let allowed = !code.isEmpty && code.count <= 80
            && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        self.code = allowed ? code : "cloud_request_failed"
    }

    public static let networkUnavailable = CloudFailure("cloud_network_unavailable")
    public static let unavailable = CloudFailure("cloud_unavailable")
    public static let responseInvalid = CloudFailure("cloud_response_invalid")
    public static let notConnected = CloudFailure("cloud_not_connected")
    public static let sessionExpired = CloudFailure("cloud_session_expired")
    public static let sessionChanged = CloudFailure("cloud_session_changed")
    public static let keychainUnavailable = CloudFailure("cloud_keychain_unavailable")
    public static let entitlementInvalid = CloudFailure("cloud_entitlement_invalid")
    public static let accountMismatch = CloudFailure("cloud_account_mismatch")
    public static let deviceLimitReached = CloudFailure("device_limit_reached")
    public static let deviceRevoked = CloudFailure("device_revoked")
    public static let accountNotActive = CloudFailure("account_not_active")
    public static let appleSubscriptionActive = CloudFailure("apple_subscription_active")
    public static let authCancelled = CloudFailure("cloud_auth_cancelled")
    public static let authDenied = CloudFailure("cloud_auth_denied")
    public static let authStateMismatch = CloudFailure("cloud_auth_state_mismatch")
    public static let authCallbackInvalid = CloudFailure("cloud_auth_callback_invalid")
    public static let transactionInvalid = CloudFailure("storekit_transaction_invalid")

    /// The server cannot be reached right now: the last signed rights still apply.
    public var isConnectivity: Bool {
        self == .networkUnavailable || self == .unavailable
    }
}
