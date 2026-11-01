import Foundation

enum CloudDate {
    /// The API writes ISO 8601, with or without fractional seconds.
    static func parse(_ value: String) -> Date? {
        (try? Date(value, strategy: .iso8601))
            ?? (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

public enum EntitlementTier: String, Codable, Sendable { case free, pro }

public enum EntitlementSource: String, Codable, Sendable {
    case none, trial, stripe, support
    case appStore = "app_store"
}

public struct AccountDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let platform: String
    public let lastSeenAt: String
    public let createdAt: String

    public init(id: String, displayName: String, platform: String, lastSeenAt: String, createdAt: String) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
    }

    public var lastSeen: Date? { CloudDate.parse(lastSeenAt) }
}

/// A device removed from the account. Only this iPhone can use its own restoration.
public struct RevokedDevice: Equatable, Sendable, Identifiable {
    public let device: AccountDevice
    public let isThisIPhone: Bool

    public var id: String { device.id }

    public init(device: AccountDevice, isThisIPhone: Bool) {
        self.device = device
        self.isThisIPhone = isThisIPhone
    }
}

public struct BillingStatus: Codable, Equatable, Sendable {
    public let provider: String?
    public let interval: String?
    public let status: String?
    public let currentPeriodEndsAt: String?
    public let cancelAtPeriodEnd: Bool

    public init(provider: String?, interval: String?, status: String?, currentPeriodEndsAt: String?, cancelAtPeriodEnd: Bool) {
        self.provider = provider
        self.interval = interval
        self.status = status
        self.currentPeriodEndsAt = currentPeriodEndsAt
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
    }

    public var periodEnd: Date? { currentPeriodEndsAt.flatMap(CloudDate.parse) }
}

struct OAuthMetadata: Decodable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?

    private enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
    }
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct BootstrapRequest: Encodable {
    let deviceIdentifier: String
    let displayName: String
    let appVariant: String
    let appVersion: String
    let platform: String
}

struct BootstrapResponse: Decodable {
    struct Device: Decodable { let id: String }
    let accountId: String
    let device: Device
}

struct MeResponse: Decodable {
    let accountId: String
    let email: String
}

struct EntitlementResponse: Decodable {
    struct Signed: Decodable {
        let token: String
        let keyId: String
    }
    let signedSnapshot: Signed
}

struct DeviceListResponse: Decodable {
    let devices: [AccountDevice]
    let revokedDevices: [AccountDevice]?
}

struct RestoreAppStoreRequest: Encodable {
    let signedTransaction: String
    /// Sent only after the user confirmed that a purchase made elsewhere belongs to this account.
    let linkToCurrentAccount: Bool?
}

struct RestoreAppStoreResponse: Decodable {
    let restored: Bool
}
