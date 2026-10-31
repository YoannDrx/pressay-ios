import Foundation

/// The one keyboard instance allowed to insert.
///
/// iOS keeps earlier instances of a keyboard alive in the same process. In spike S3 an older
/// instance inserted into a field that was no longer on screen: only the instance that
/// appeared last, and has not disappeared since, may take a result. iOS can show the new
/// instance before it hides the old one, so hiding only clears the slot it still holds.
@MainActor
public final class VisibleInstance<Instance: AnyObject> {
    public private(set) weak var current: Instance?

    public init() {}

    public func appeared(_ instance: Instance) {
        current = instance
    }

    public func disappeared(_ instance: Instance) {
        if current === instance {
            current = nil
        }
    }

    public func isVisible(_ instance: Instance) -> Bool {
        current === instance
    }
}

/// Hands results from the queue to the visible keyboard, each at most once.
public struct ResultDelivery: Sendable {
    /// A result dictated while the keyboard was hidden is inserted when it comes back only
    /// within this delay; later, it would land in an unrelated field. It stays in the app's
    /// history either way.
    public static let maximumAge: TimeInterval = 120

    public let queue: ResultQueue

    public init(queue: ResultQueue) {
        self.queue = queue
    }

    /// Takes the next result to insert. `alreadyInserted` guards against a result seen twice
    /// in this process; the queue's lock guards across processes.
    public func next(now: Date = Date(), alreadyInserted: Set<UUID>) throws -> DictationResult? {
        while let result = try queue.takeNext(now: now, maxAge: Self.maximumAge) {
            if !alreadyInserted.contains(result.id) {
                return result
            }
        }
        return nil
    }
}

public enum InsertionText {
    /// Characters after which a dictation starts without a space.
    private static let openers: Set<Character> = ["(", "[", "{", "«", "“", "‘", "\"", "'", "’", "/", "@", "#", "-"]

    /// Adds the space a dictation needs after a word typed before the cursor.
    public static func prepare(_ text: String, contextBefore: String?) -> String {
        guard let first = text.first, !first.isWhitespace,
              let last = contextBefore?.last, !last.isWhitespace, !openers.contains(last)
        else { return text }
        if [",", ".", "!", "?", ";", ":", "…"].contains(first) {
            return text
        }
        return " " + text
    }
}

/// "Undo insertion": removes the text a dictation inserted while the cursor still sits
/// right after it.
public struct InsertionUndo: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var deletionCount: Int { text.count }

    /// `contextBefore` may be truncated by the host app: a context shorter than the text
    /// must then be its end.
    public func isAvailable(contextBefore: String?) -> Bool {
        guard let before = contextBefore, !before.isEmpty, !text.isEmpty else { return false }
        if before.hasSuffix(text) { return true }
        return before.count >= 8 && text.hasSuffix(before)
    }
}

/// What the Pressay bar above the keys shows.
public enum KeyboardBarState: Sendable, Equatable {
    case ready
    case listening
    case transcribing
    case inserted
    case failed
    /// The microphone button got no answer: the app is not running, or iOS suspended it.
    case actionButtonHint

    /// Past these delays a phase is stale: the app died or was suspended mid-way.
    public static let recordingTimeout: TimeInterval = 330
    public static let transcribingTimeout: TimeInterval = 120
    /// How long a delivery or a failure stays on screen.
    public static let outcomeDuration: TimeInterval = 8
    /// How long the app has to answer the microphone button.
    public static let toggleAnswerTimeout: TimeInterval = 1.5
    /// How long the hint stays once shown.
    public static let hintDuration: TimeInterval = 6

    public static func resolve(
        phase: DictationPhase,
        phaseChangedAt: Date?,
        lastInsertionAt: Date?,
        toggleRequestedAt: Date?,
        now: Date
    ) -> KeyboardBarState {
        let phaseAge = phaseChangedAt.map { now.timeIntervalSince($0) } ?? .infinity
        switch phase {
        case .recording where phaseAge < recordingTimeout:
            return .listening
        case .transcribing where phaseAge < transcribingTimeout:
            return .transcribing
        default:
            break
        }
        // The microphone was tapped after the last phase change and nothing happened.
        if let toggleRequestedAt {
            let waited = now.timeIntervalSince(toggleRequestedAt)
            let unanswered = phaseChangedAt.map { $0 < toggleRequestedAt } ?? true
            if unanswered, waited >= toggleAnswerTimeout, waited < toggleAnswerTimeout + hintDuration {
                return .actionButtonHint
            }
        }
        if let lastInsertionAt, now.timeIntervalSince(lastInsertionAt) < outcomeDuration {
            return .inserted
        }
        if phase == .failed, phaseAge < outcomeDuration {
            return .failed
        }
        return .ready
    }

    /// The next moment the state may change without any signal, to refresh the bar then.
    public static func nextChange(
        phaseChangedAt: Date?,
        lastInsertionAt: Date?,
        toggleRequestedAt: Date?,
        now: Date
    ) -> Date? {
        var candidates: [Date] = []
        if let phaseChangedAt {
            candidates += [outcomeDuration, transcribingTimeout, recordingTimeout].map { phaseChangedAt + $0 }
        }
        if let lastInsertionAt {
            candidates.append(lastInsertionAt + outcomeDuration)
        }
        if let toggleRequestedAt {
            candidates += [toggleAnswerTimeout, toggleAnswerTimeout + hintDuration].map { toggleRequestedAt + $0 }
        }
        return candidates.filter { $0 > now }.min()
    }
}
