import Foundation

/// The Free and Pro limits on iPhone (`IOS_LAUNCH_PLAN.md`, section 6). The paywall never punishes
/// the base act: local dictation stays free and unlimited, and nothing here can stop it.
public enum ProLimits {
    /// Words a Free user can add. Words already there keep working after a subscription ends.
    public static let freeDictionaryEntries = 20
    /// Successful AI rewrites a Free user can try.
    public static let freeAITrials = 3
    /// Days of history a Free user sees. Older dictations stay sealed on the iPhone until Pro
    /// returns or the user clears them.
    public static let freeHistoryDays = 7
    /// The Mac's own limit, so a synced dictionary always fits on both sides.
    public static let maximumDictionaryEntries = 5_000

    public static func canAddDictionaryEntry(count: Int, isPro: Bool) -> Bool {
        count < (isPro ? maximumDictionaryEntries : freeDictionaryEntries)
    }
}

/// Counts the free AI trials in the Keychain, so a reinstall does not hand out new ones.
public struct AITrialCounter: Sendable {
    private static let key = "ai-trials-used-v1"
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public var used: Int {
        guard let data = try? secrets.data(for: Self.key), let text = String(data: data, encoding: .utf8) else { return 0 }
        return Int(text) ?? 0
    }

    public var remaining: Int {
        max(0, ProLimits.freeAITrials - used)
    }

    public func consume() {
        try? secrets.set(Data(String(used + 1).utf8), for: Self.key)
    }
}
