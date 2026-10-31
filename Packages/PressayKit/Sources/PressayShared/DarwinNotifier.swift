import Foundation

/// Signal names shared by the app and its extensions.
public enum PressaySignal {
    public static let phaseChanged = "fr.yodev.pressay.phase"
    public static let resultReady = "fr.yodev.pressay.result"
    public static let keyboardRequestsToggle = "fr.yodev.pressay.keyboard-toggle"
}

/// Cross-process signals between the app and its extensions. Darwin notifications carry
/// no payload: the receiver reads the App Group to learn what changed.
///
/// Each process registers one system observer per name, whatever the number of handlers:
/// iOS keeps stale keyboard instances alive, and one observer each would insert twice.
public enum DarwinNotifier {
    nonisolated(unsafe) private static var handlers: [String: [@Sendable () -> Void]] = [:] // guarded by `lock`
    private static let lock = NSLock()

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    public static func observe(_ name: String, handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let isFirst = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard isFirst else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, cfName, _, _ in
                guard let raw = cfName?.rawValue as String? else { return }
                DarwinNotifier.dispatch(raw)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private static func dispatch(_ name: String) {
        lock.lock()
        let callbacks = handlers[name] ?? []
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
