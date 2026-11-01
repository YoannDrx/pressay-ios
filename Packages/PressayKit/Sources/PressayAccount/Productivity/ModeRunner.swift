import Foundation

/// Why a rewrite gave way to the dictated text. Short codes for the journal.
public enum RewriteFallback: String, Equatable, Sendable {
    case modelUnavailable
    case rateLimited
    case timedOut
    case refused
    case failed
    case emptyResult
    case trialsExhausted
}

/// A failed rewrite, thrown by a `TextRewriter`. Holds no text.
public struct RewriteFailure: Error, Equatable, Sendable {
    public let reason: RewriteFallback

    public init(_ reason: RewriteFallback) {
        self.reason = reason
    }
}

/// The model behind AI modes: Foundation Models in the app, a stub in tests.
public protocol TextRewriter: Sendable {
    func rewrite(_ text: String, instructions: String) async throws -> String
}

public struct ModeOutcome: Equatable, Sendable {
    public let text: String
    /// Set when the mode ran and produced `text`.
    public let appliedModeID: String?
    /// Set when the dictated text was delivered instead of the mode's result.
    public let fallback: RewriteFallback?
}

/// Runs a mode with one rule above all: a dictation always yields text. Whatever goes wrong with
/// the model, the dictated text is delivered and nothing blocks.
public struct ModeRunner: Sendable {
    /// A keyboard is waiting for this text: past this delay, it gets the dictated text.
    public static let defaultTimeout: Duration = .seconds(12)

    let trials: AITrialCounter
    let rewriter: any TextRewriter
    let timeout: Duration

    public init(trials: AITrialCounter, rewriter: any TextRewriter, timeout: Duration = Self.defaultTimeout) {
        self.trials = trials
        self.rewriter = rewriter
        self.timeout = timeout
    }

    public func run(_ mode: PressayMode, on text: String, dictionaryTerms: [String], isPro: Bool) async -> ModeOutcome {
        guard let instructions = mode.modelInstructions(dictionaryTerms: dictionaryTerms, dictated: text) else {
            return ModeOutcome(text: text, appliedModeID: nil, fallback: nil)
        }
        guard isPro || trials.remaining > 0 else {
            return ModeOutcome(text: text, appliedModeID: nil, fallback: .trialsExhausted)
        }
        do {
            let rewriter = rewriter
            let rewritten = try await Self.withTimeout(timeout) {
                try await rewriter.rewrite(text, instructions: instructions)
            }
            let trimmed = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ModeOutcome(text: text, appliedModeID: nil, fallback: .emptyResult)
            }
            if !isPro {
                // Only a result counts as a trial: a model that fails costs nothing.
                trials.consume()
            }
            return ModeOutcome(text: trimmed, appliedModeID: mode.id, fallback: nil)
        } catch let failure as RewriteFailure {
            return ModeOutcome(text: text, appliedModeID: nil, fallback: failure.reason)
        } catch {
            return ModeOutcome(text: text, appliedModeID: nil, fallback: .failed)
        }
    }

    private static func withTimeout(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RewriteFailure(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RewriteFailure(.failed) }
            return first
        }
    }
}
