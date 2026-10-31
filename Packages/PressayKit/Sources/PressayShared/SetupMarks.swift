import Foundation

/// Evidence the keyboard and the app leave in the App Group so the setup guide can tick its
/// steps by itself: iOS never tells an app whether its keyboard has Full Access or what the
/// Action button runs. Only dates, never content.
public struct SetupMarks: @unchecked Sendable {
    // UserDefaults is thread-safe; it is only not annotated as Sendable.
    private let defaults: UserDefaults
    private let notify: Bool

    public init(defaults: UserDefaults, notify: Bool = true) {
        self.defaults = defaults
        self.notify = notify
    }

    /// Nil when the App Group is unreachable: in the keyboard, that means no Full Access.
    public static var shared: SetupMarks? {
        AppGroup.defaults.map { SetupMarks(defaults: $0) }
    }

    private enum Key {
        static let keyboardFullAccess = "setup.keyboardFullAccessAt"
        static let insertion = "setup.lastInsertionAt"
        static let intent = "setup.intentUsedAt"
    }

    /// The keyboard appeared with Full Access. It can only write this mark with Full Access,
    /// so the mark proves both that the keyboard is added and that Full Access is on.
    public var keyboardFullAccessAt: Date? { date(Key.keyboardFullAccess) }

    /// The keyboard inserted a dictation.
    public var lastInsertionAt: Date? { date(Key.insertion) }

    /// A dictation started from the Action button, Control Center, the Lock Screen or Siri.
    public var intentUsedAt: Date? { date(Key.intent) }

    public func markKeyboardFullAccess(at date: Date = Date()) {
        // Written at every appearance; posting each time would wake the app for nothing.
        let isFirst = keyboardFullAccessAt == nil
        set(Key.keyboardFullAccess, date)
        if isFirst { post() }
    }

    public func markInsertion(at date: Date = Date()) {
        set(Key.insertion, date)
        post()
    }

    public func markIntentUsed(at date: Date = Date()) {
        set(Key.intent, date)
        post()
    }

    /// Forgets every mark, so the guide can be replayed from scratch.
    public func reset() {
        [Key.keyboardFullAccess, Key.insertion, Key.intent].forEach(defaults.removeObject(forKey:))
    }

    private func date(_ key: String) -> Date? {
        let seconds = defaults.double(forKey: key)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private func set(_ key: String, _ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    private func post() {
        if notify {
            DarwinNotifier.post(PressaySignal.setupChanged)
        }
    }
}
