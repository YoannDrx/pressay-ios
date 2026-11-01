import Foundation
import FoundationModels
import PressayAccount

/// AI modes with Apple's on-device model: nothing leaves the iPhone. Every failure maps to a reason
/// `ModeRunner` answers with the dictated text, including the `rateLimited` iOS applies in the
/// background (decision D8).
struct FoundationModelsRewriter: TextRewriter {
    func rewrite(_ text: String, instructions: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw RewriteFailure(.modelUnavailable)
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: text, options: GenerationOptions(temperature: 0.2))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw RewriteFailure(Self.reason(for: error))
        }
    }

    private static func reason(for error: LanguageModelSession.GenerationError) -> RewriteFallback {
        switch error {
        case .rateLimited, .concurrentRequests: .rateLimited
        case .guardrailViolation, .refusal: .refused
        case .assetsUnavailable, .unsupportedLanguageOrLocale: .modelUnavailable
        default: .failed
        }
    }
}

/// Whether the model can run here, for the modes screen. Never a condition for dictating.
enum ModelAvailability: Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceOff
    case notReady
    case unknown

    static var current: ModelAvailability {
        #if DEBUG
        if let stub = DebugRewriter.current?.availability { return stub }
        #endif
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .notReady
            @unknown default: return .unknown
            }
        }
    }
}

enum Rewriters {
    static var current: any TextRewriter {
        #if DEBUG
        if let stub = DebugRewriter.current { return stub }
        #endif
        return FoundationModelsRewriter()
    }
}

#if DEBUG
/// `-PressayRewriter echo|rateLimited|unavailable` replaces the model in debug builds: the
/// simulator rarely has one, and the fallback must be seen working.
struct DebugRewriter: TextRewriter {
    let behavior: String

    static var current: DebugRewriter? {
        let value = ProcessInfo.processInfo.environment["PressayRewriter"] ?? UserDefaults.standard.string(forKey: "PressayRewriter")
        return value.map(DebugRewriter.init(behavior:))
    }

    var availability: ModelAvailability {
        behavior == "unavailable" ? .deviceNotEligible : .available
    }

    func rewrite(_ text: String, instructions: String) async throws -> String {
        switch behavior {
        case "rateLimited": throw RewriteFailure(.rateLimited)
        case "unavailable": throw RewriteFailure(.modelUnavailable)
        default: return "[AI] \(text)"
        }
    }
}
#endif
