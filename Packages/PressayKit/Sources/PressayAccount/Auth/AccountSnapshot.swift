import Foundation

/// What the app needs to know about the account at any moment.
public struct AccountSnapshot: Equatable, Sendable {
    public enum Connection: Equatable, Sendable {
        case signedOut
        /// Signed in, but this iPhone holds no device slot yet: the last attempt did not finish.
        case awaitingDevice
        /// Signed in, but the account already has three active devices.
        case deviceLimitReached
        /// Signed in, but this iPhone was removed from the account. The cloud refuses it until its
        /// owner restores it.
        case deviceRevoked
        case connected
    }

    public var connection: Connection
    public var accountID: String?
    public var deviceID: String?
    /// Known only after a successful online refresh, and kept in memory only.
    public var email: String?
    /// The last signed rights that are still valid. Nil means Free.
    public var entitlement: VerifiedEntitlement?
    /// The refresh token was refused: Pro lasts until the signed rights expire, then a new sign-in
    /// is needed.
    public var sessionExpired: Bool

    public static let signedOut = AccountSnapshot(connection: .signedOut, sessionExpired: false)

    public init(
        connection: Connection,
        accountID: String? = nil,
        deviceID: String? = nil,
        email: String? = nil,
        entitlement: VerifiedEntitlement? = nil,
        sessionExpired: Bool
    ) {
        self.connection = connection
        self.accountID = accountID
        self.deviceID = deviceID
        self.email = email
        self.entitlement = entitlement
        self.sessionExpired = sessionExpired
    }

    public var isPro: Bool { entitlement?.tier == .pro }
}
