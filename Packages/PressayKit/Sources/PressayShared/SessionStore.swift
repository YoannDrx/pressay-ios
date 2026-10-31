import Foundation

/// Where the current dictation stands. The widgets and the keyboard only read it.
public enum DictationPhase: String, Codable, Sendable, CaseIterable {
    case idle, recording, transcribing, delivered, failed
}

/// The session state in the App Group's defaults. Every change posts
/// `PressaySignal.phaseChanged` so the other processes re-read it.
public struct SessionStore: @unchecked Sendable {
    // UserDefaults is thread-safe; it is only not annotated as Sendable.
    private let defaults: UserDefaults
    private let notify: Bool

    public init(defaults: UserDefaults, notify: Bool = true) {
        self.defaults = defaults
        self.notify = notify
    }

    /// The store in the App Group, or nil when the container is unreachable.
    public static var shared: SessionStore? {
        AppGroup.defaults.map { SessionStore(defaults: $0) }
    }

    private enum Key {
        static let phase = "session.phase"
        static let phaseChangedAt = "session.phaseChangedAt"
        static let toggleRequestedAt = "keyboard.toggleRequestedAt"
    }

    /// How long a microphone tap in the keyboard stays valid. A suspended app receives the
    /// Darwin signal only when iOS resumes it, maybe minutes later: it must not start a
    /// dictation nobody is waiting for.
    public static let toggleRequestLifetime: TimeInterval = 2

    public var phase: DictationPhase {
        defaults.string(forKey: Key.phase).flatMap(DictationPhase.init(rawValue:)) ?? .idle
    }

    public var phaseChangedAt: Date? {
        let seconds = defaults.double(forKey: Key.phaseChangedAt)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    public func setPhase(_ phase: DictationPhase, at date: Date = Date()) {
        defaults.set(phase.rawValue, forKey: Key.phase)
        defaults.set(date.timeIntervalSince1970, forKey: Key.phaseChangedAt)
        if notify {
            DarwinNotifier.post(PressaySignal.phaseChanged)
        }
    }

    // MARK: Keyboard microphone

    /// Written by the keyboard right before it posts `PressaySignal.keyboardRequestsToggle`.
    public func requestToggle(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.toggleRequestedAt)
        if notify {
            DarwinNotifier.post(PressaySignal.keyboardRequestsToggle)
        }
    }

    public var toggleRequestedAt: Date? {
        let seconds = defaults.double(forKey: Key.toggleRequestedAt)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Read by the app when the signal arrives: true once per request, and only while it is
    /// fresh.
    public func takeToggleRequest(now: Date = Date()) -> Bool {
        guard let requestedAt = toggleRequestedAt else { return false }
        defaults.removeObject(forKey: Key.toggleRequestedAt)
        let age = now.timeIntervalSince(requestedAt)
        return age >= -1 && age <= Self.toggleRequestLifetime
    }
}
