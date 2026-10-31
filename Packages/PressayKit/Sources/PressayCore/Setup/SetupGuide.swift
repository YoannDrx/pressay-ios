import Foundation

/// One step of the setup guide, in order.
public enum SetupStep: Int, CaseIterable, Sendable, Identifiable, Codable {
    case microphone, keyboard, fullAccess, trigger, firstDictation

    public var id: Int { rawValue }
}

/// What the app could observe about the setup. iOS reports none of it directly: each value
/// comes from a permission, the list of active keyboards, or a mark the keyboard or an
/// intent left in the App Group (`SetupMarks`).
public struct SetupEvidence: Equatable, Sendable {
    public var microphoneGranted: Bool
    /// The Pressay keyboard is among the active input modes.
    public var keyboardAdded: Bool
    /// The keyboard appeared at least once with Full Access.
    public var fullAccessSeen: Bool
    /// A dictation started from the Action button, Control Center or Siri.
    public var triggerUsed: Bool
    /// The user chose to skip the trigger step; the app's Dictate button still works.
    public var triggerSkipped: Bool
    /// The keyboard inserted a dictation.
    public var insertionSeen: Bool

    public init(
        microphoneGranted: Bool = false,
        keyboardAdded: Bool = false,
        fullAccessSeen: Bool = false,
        triggerUsed: Bool = false,
        triggerSkipped: Bool = false,
        insertionSeen: Bool = false
    ) {
        self.microphoneGranted = microphoneGranted
        self.keyboardAdded = keyboardAdded
        self.fullAccessSeen = fullAccessSeen
        self.triggerUsed = triggerUsed
        self.triggerSkipped = triggerSkipped
        self.insertionSeen = insertionSeen
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .microphone: microphoneGranted
        // The keyboard can only leave its mark with Full Access: the mark proves it is added,
        // even when the list of input modes is not up to date yet.
        case .keyboard: keyboardAdded || fullAccessSeen
        case .fullAccess: fullAccessSeen
        // A first insertion needs a trigger too: the keyboard's microphone works only while
        // the app runs, but it proves the user can dictate.
        case .trigger: triggerUsed || triggerSkipped
        case .firstDictation: insertionSeen
        }
    }

    public var doneCount: Int { SetupStep.allCases.filter(isDone).count }
    public var firstPending: SetupStep? { SetupStep.allCases.first { !isDone($0) } }
    public var isComplete: Bool { firstPending == nil }

    /// What Pressay needs to insert text in other apps; the trigger is a convenience.
    public var isReadyToDictate: Bool {
        microphoneGranted && isDone(.keyboard) && fullAccessSeen
    }
}

/// Where the guide opens: the step the user left, unless it is done since, in which case
/// the first step still to do.
public enum SetupResume {
    public static func step(saved: SetupStep?, evidence: SetupEvidence) -> SetupStep? {
        if let saved, !evidence.isDone(saved) {
            return saved
        }
        return evidence.firstPending
    }
}

/// iPhones with an Action button: 15 Pro and later, the whole 16 and 17 ranges. Others start
/// a dictation from Control Center, the Lock Screen or Back Tap instead.
public enum ActionButtonSupport {
    /// `modelIdentifier` is the hardware model, such as "iPhone17,3".
    public static func isAvailable(modelIdentifier: String) -> Bool {
        guard modelIdentifier.hasPrefix("iPhone") else { return false }
        let numbers = modelIdentifier.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 2 else { return false }
        let (major, minor) = (numbers[0], numbers[1])
        // iPhone16,1 and 16,2 are the 15 Pro and 15 Pro Max; every iPhone17,x and later has one.
        return major >= 17 || (major == 16 && (1...2).contains(minor))
    }
}
