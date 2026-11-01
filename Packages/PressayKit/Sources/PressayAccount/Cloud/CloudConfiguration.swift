import Foundation

/// Where the account lives. Everything here is public: the OAuth client has no secret (PKCE) and
/// the entitlement key only verifies. Same issuer, client and key as the Mac app.
public struct CloudConfiguration: Sendable {
    public var apiBaseURL: URL
    public var oauthIssuer: URL
    public var oauthClientID: String
    public var oauthResource: String
    public var entitlementKeyID: String
    /// Ed25519 public key, base64url without padding.
    public var entitlementPublicKey: String
    public var entitlementIssuer: String
    /// Debug builds pointed at a local fake server only.
    public var allowsLocalhost: Bool

    public static let redirectURI = "pressay://oauth/callback"
    public static let callbackScheme = "pressay"
    public static let scope = "openid profile email offline_access"
    /// The audience of an entitlement token for the App Store bundle shared with the Mac.
    public static let entitlementAudience = "fr.yodev.pressay"

    public init(
        apiBaseURL: URL,
        oauthIssuer: URL,
        oauthClientID: String,
        oauthResource: String,
        entitlementKeyID: String,
        entitlementPublicKey: String,
        entitlementIssuer: String,
        allowsLocalhost: Bool = false
    ) {
        self.apiBaseURL = apiBaseURL
        self.oauthIssuer = oauthIssuer
        self.oauthClientID = oauthClientID
        self.oauthResource = oauthResource
        self.entitlementKeyID = entitlementKeyID
        self.entitlementPublicKey = entitlementPublicKey
        self.entitlementIssuer = entitlementIssuer
        self.allowsLocalhost = allowsLocalhost
    }

    public static let production = CloudConfiguration(
        apiBaseURL: URL(string: "https://api.press-say.app")!,
        oauthIssuer: URL(string: "https://press-say.app")!,
        oauthClientID: "w9ckUgrcFp7H7wNV",
        oauthResource: "https://api.press-say.app",
        entitlementKeyID: "pressay-entitlement-production-2026-01",
        entitlementPublicKey: "Xm5Rqwpjhv85nc7Y_Lrf3S7M40iCozJCrFh1UCXeoF0",
        entitlementIssuer: "https://api.press-say.app"
    )

    /// The issuer's metadata comes from the network: its endpoints must stay on the issuer's host.
    public func validateOAuthEndpoint(_ url: URL) throws {
        let host = url.host()
        if url.scheme == "https", host == oauthIssuer.host() { return }
        if allowsLocalhost, url.scheme == "http", host == "127.0.0.1" || host == "localhost" { return }
        throw CloudFailure("cloud_oauth_endpoint_invalid")
    }
}
