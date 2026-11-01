import CryptoKit
import Foundation

/// A provider hint for the web sign-in page, which otherwise lists every option. Apple comes first
/// in the interface and never depends on the network (App Review 4.8).
public enum SignInProvider: String, CaseIterable, Sendable {
    case apple, google
}

/// One PKCE attempt. Lives in memory only: `ASWebAuthenticationSession` hands the callback back to
/// this process, so nothing about the attempt ever reaches the disk.
public struct SignInRequest: Sendable {
    public let url: URL
    let state: String
    let verifier: String
    let tokenEndpoint: URL
    let createdAt: Date

    /// Same limit as the Mac app.
    static let lifetime: TimeInterval = 15 * 60

    static func randomToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    static func authorizationURL(
        endpoint: URL,
        configuration: CloudConfiguration,
        provider: SignInProvider?,
        state: String,
        verifier: String
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw CloudFailure("cloud_oauth_endpoint_invalid")
        }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.oauthClientID),
            URLQueryItem(name: "redirect_uri", value: CloudConfiguration.redirectURI),
            URLQueryItem(name: "scope", value: CloudConfiguration.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: configuration.oauthResource),
        ]
        if let provider {
            items.append(URLQueryItem(name: "provider", value: provider.rawValue))
        }
        components.queryItems = items
        guard let url = components.url else { throw CloudFailure("cloud_oauth_endpoint_invalid") }
        return url
    }

    /// The authorization code of a callback that answers this very attempt.
    func code(fromCallback callback: URL, now: Date) throws -> String {
        guard callback.scheme == CloudConfiguration.callbackScheme, callback.host() == "oauth",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { throw CloudFailure.authCallbackInvalid }
        let first = { (name: String) in items.first { $0.name == name }?.value }
        guard first("state") == state, now.timeIntervalSince(createdAt) <= Self.lifetime else {
            throw CloudFailure.authStateMismatch
        }
        if first("error") != nil || callback.path() == "/error" {
            throw CloudFailure.authDenied
        }
        guard callback.path() == "/callback", let code = first("code"), !code.isEmpty, code.count <= 4096 else {
            throw CloudFailure.authCallbackInvalid
        }
        return code
    }
}
