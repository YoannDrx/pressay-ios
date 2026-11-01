import Foundation
import PressayAccount
import PressayShared

/// The account layer's singletons. Nothing here reaches the network until the user signs in, and
/// the keyboard links none of it.
enum AccountEnvironment {
    static let secrets: any SecretStore = KeychainSecretStore()

    static let configuration: CloudConfiguration = {
        #if DEBUG
        if let debug = debugConfiguration { return debug }
        #endif
        return .production
    }()

    static let account: AccountService = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let service = try? AccountService(
            configuration: configuration,
            transport: URLSessionTransport(),
            secrets: secrets,
            appVersion: version,
            log: PressayLog.shared
        ) else {
            preconditionFailure("The entitlement key compiled into the app is invalid")
        }
        return service
    }()

    static let productivity = ProductivityStore.applicationSupport(secrets: secrets)

    static let sync = SyncService(
        account: account,
        secrets: secrets,
        store: productivity,
        stateStore: FileSyncStateStore.applicationSupport,
        log: PressayLog.shared
    )

    static let trials = AITrialCounter(secrets: secrets)

    #if DEBUG
    /// A local fake server (`scripts/fake-cloud.mjs`), from launch arguments or from the
    /// environment of a hosted test. Compiled out of release builds, which only know production.
    private static var debugConfiguration: CloudConfiguration? {
        func value(_ name: String) -> String? {
            ProcessInfo.processInfo.environment[name] ?? UserDefaults.standard.string(forKey: name)
        }
        guard let api = value("PressayCloudURL").flatMap(URL.init(string:)),
              let key = value("PressayEntitlementKey"),
              let keyID = value("PressayEntitlementKeyID")
        else { return nil }
        return CloudConfiguration(
            apiBaseURL: api,
            oauthIssuer: api,
            oauthClientID: "fake-client",
            oauthResource: api.absoluteString,
            entitlementKeyID: keyID,
            entitlementPublicKey: key,
            entitlementIssuer: "https://api.press-say.app",
            allowsLocalhost: true
        )
    }
    #endif
}
