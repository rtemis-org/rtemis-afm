// ErrorMapper.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels

/// Translates errors thrown by the FoundationModels framework into
/// `BridgeError`s with an honest HTTP status (spec: rtemis-afm/wire#errors).
///
/// The framework's errors (macOS 27 SDK, September 2026):
///
/// - `LanguageModelError` — generation failures, introduced in macOS 27 with
///   the `LanguageModel` protocol. `SystemLanguageModel` throws it for
///   binaries built against macOS 27 (the older
///   `LanguageModelSession.GenerationError` is deprecated and only thrown
///   to binaries linked against macOS 26 — `afm-spike` check F2 confirms
///   which one arrives).
/// - `SystemLanguageModel.Error.assetsUnavailable` — the model files are
///   not on disk.
/// - `LanguageModelSession.Error` — misuse of a session (concurrent calls).
/// - `LanguageModelSession.ToolCallError` — a tool threw.
///
/// **Future updates:** when a new macOS SDK lands, diff these switches
/// against the cases in `FoundationModels.swiftinterface` (see `afm-spike`)
/// and add any new case; an unmapped case falls through to `500 server_error`.
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

        if let modelError = error as? LanguageModelError {
            return map(modelError)
        }

        if let sessionError = error as? LanguageModelSession.Error {
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

        if let assets = error as? SystemLanguageModel.Error {
            return .modelUnavailable(describe(assets))
        }

        if error is GenerationSchema.SchemaError {
            return .invalidRequest("Unsupported schema: \(describe(error))", code: "unsupported_schema")
        }

        if let parsing = error as? GeneratedContent.ParsingError {
            return .invalidRequest("Could not parse generated content: \(parsing.debugDescription)")
        }

        if error is CancellationError {
            // The client went away; the status is moot but keep it sensible.
            return BridgeError(status: 499, type: "server_error", code: "cancelled", message: "Request cancelled")
        }

        // With tools attached, the macOS 27.0 framework reports an oversized
        // transcript through an internal type (`GenerativeError`, absent
        // from the public interface) instead of
        // `LanguageModelError.contextSizeExceeded`; only its message says
        // what happened (spike check F3). Matched here so the client gets
        // the same 400 either way.
        let message = describe(error)
        if isContextOverflowMessage(message) {
            return BridgeError(status: 400, type: "invalid_request_error", code: "context_length_exceeded", message: message)
        }

        // Unmapped: say which type it was, so the log and the client point
        // at the case to add above.
        return .serverError("\(type(of: error)): \(message)")
    }

    /// "Provided 8,226 tokens, but the maximum allowed is 8,192." — the
    /// internal error's wording on macOS 27.0.
    static func isContextOverflowMessage(_ message: String) -> Bool {
        message.contains("tokens, but the maximum allowed is")
    }

    /// Generation failures.
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
            // Refusals are normally turned into a 200 with `message.refusal`
            // by the engine; reaching here means it happened somewhere the
            // engine could not intercept.
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
