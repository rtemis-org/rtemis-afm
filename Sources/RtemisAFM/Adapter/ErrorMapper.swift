// ErrorMapper.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels

/// Translates errors thrown by the FoundationModels framework into
/// `BridgeError`s with an honest HTTP status.
///
/// Two error families exist side by side (September 2026, macOS 27 SDK):
///
/// - `LanguageModelSession.GenerationError` — the macOS 26 enum, still what
///   `SystemLanguageModel` throws in practice.
/// - `LanguageModelError` — introduced in macOS 27 alongside the
///   `LanguageModel` protocol, thrown by third-party and cloud models and
///   possibly by the system model in a future release.
///
/// Both are handled so the mapping keeps working whichever one shows up.
/// **Future updates:** when a new macOS SDK lands, diff this switch against
/// the cases in `FoundationModels.swiftinterface` (see `afm-spike`) and
/// add any new case; an unmapped case falls through to `500 server_error`.
public enum ErrorMapper {
    /// The `BridgeError` for any error that escaped a generation.
    public static func map(_ error: any Error) -> BridgeError {
        // Already ours — nothing to translate.
        if let bridge = error as? BridgeError { return bridge }

        // A tool threw. The bridge's own tools throw `ToolCallIntercepted`
        // on purpose (see `BridgeTool`), and the engine catches that before
        // it gets here, so anything else is a genuine failure.
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return map(toolError.underlyingError)
        }

        if let generation = error as? LanguageModelSession.GenerationError {
            return map(generation)
        }

        if #available(macOS 27, *), let modelError = error as? LanguageModelError {
            return map(modelError)
        }

        if #available(macOS 27, *), let sessionError = error as? LanguageModelSession.Error {
            switch sessionError {
            case .concurrentRequests:
                // The generation gate serializes requests, so this should
                // never surface; if it does, 429 is the honest answer.
                return BridgeError(status: 429, type: "rate_limit_exceeded", code: "concurrent_requests",
                                   message: describe(sessionError))
            case .transcriptMutationWhileResponding:
                return .serverError(describe(sessionError))
            @unknown default:
                return .serverError(describe(sessionError))
            }
        }

        if #available(macOS 27, *), let assets = error as? SystemLanguageModel.Error {
            return .modelUnavailable(describe(assets))
        }

        if error is GenerationSchema.SchemaError {
            return .invalidRequest("Unsupported schema: \(describe(error))", code: "unsupported_schema")
        }

        if #available(macOS 27, *), let parsing = error as? GeneratedContent.ParsingError {
            return .invalidRequest("Could not parse generated content: \(parsing.debugDescription)")
        }

        if error is CancellationError {
            // The client went away; the status is moot but keep it sensible.
            return BridgeError(status: 499, type: "server_error", code: "cancelled", message: "Request cancelled")
        }

        return .serverError(describe(error))
    }

    /// The macOS 26 error enum.
    static func map(_ error: LanguageModelSession.GenerationError) -> BridgeError {
        let message = describe(error)
        switch error {
        case .exceededContextWindowSize:
            return BridgeError(status: 400, type: "invalid_request_error", code: "context_length_exceeded", message: message)
        case .guardrailViolation:
            return BridgeError(status: 400, type: "content_filter", code: "content_filter", message: message)
        case .unsupportedGuide, .unsupportedLanguageOrLocale, .decodingFailure:
            return .invalidRequest(message)
        case .assetsUnavailable:
            return .modelUnavailable(message)
        case .rateLimited:
            return BridgeError(status: 429, type: "rate_limit_exceeded", code: "rate_limit_exceeded", message: message)
        case .concurrentRequests:
            return BridgeError(status: 429, type: "rate_limit_exceeded", code: "concurrent_requests", message: message)
        case .refusal:
            // Refusals are normally turned into a 200 with `message.refusal`
            // by the engine; reaching here means it happened somewhere the
            // engine could not intercept.
            return BridgeError(status: 400, type: "content_filter", code: "refusal", message: message)
        @unknown default:
            return .serverError(message)
        }
    }

    /// The macOS 27 error enum.
    @available(macOS 27, *)
    static func map(_ error: LanguageModelError) -> BridgeError {
        let message = describe(error)
        switch error {
        case .contextSizeExceeded(let info):
            return BridgeError(
                status: 400, type: "invalid_request_error", code: "context_length_exceeded",
                message: "\(message) (\(info.tokenCount) tokens, context size \(info.contextSize))"
            )
        case .guardrailViolation:
            return BridgeError(status: 400, type: "content_filter", code: "content_filter", message: message)
        case .refusal:
            return BridgeError(status: 400, type: "content_filter", code: "refusal", message: message)
        case .rateLimited:
            return BridgeError(status: 429, type: "rate_limit_exceeded", code: "rate_limit_exceeded", message: message)
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide,
             .unsupportedLanguageOrLocale:
            return .invalidRequest(message)
        case .timeout:
            return BridgeError(status: 504, type: "server_error", code: "timeout", message: message)
        @unknown default:
            return .serverError(message)
        }
    }

    /// A readable message for any error. `LocalizedError.errorDescription`
    /// is what the framework fills in; `String(describing:)` is the fallback.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        return String(describing: error)
    }
}
