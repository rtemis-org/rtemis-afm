// FoundationModelsBackend.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels
import Logging

/// The real backend: runs chat completions on `SystemLanguageModel`.
///
/// Each request gets its own `LanguageModelSession`, built from the
/// transcript `RequestPreparer` assembled. Generation always goes through
/// `streamResponse`, even for non-streaming clients — one code path, and
/// the server decides how to render the events.
///
/// **Future updates:** the whole file is written against the macOS 27.0 SDK
/// (Xcode 27.0, September 2026). Places that depend on macOS 27 behavior are
/// guarded with `#available(macOS 27, *)` and fall back to a poorer but
/// working answer on macOS 26. Re-run `afm-spike` after OS/Xcode updates to
/// confirm the assumptions listed in its README still hold.
public final class FoundationModelsBackend: ChatBackend {
    private let model: SystemLanguageModel
    private let gate: GenerationGate
    private let logger: Logger

    /// - Parameters:
    ///   - concurrency: how many generations may run at once (see
    ///     `GenerationGate`). Two is a sensible default on any Apple silicon Mac.
    public init(model: SystemLanguageModel = .default, concurrency: Int = 2, logger: Logger = Logger(label: "rtemis-afm.backend")) {
        self.model = model
        self.gate = GenerationGate(limit: concurrency)
        self.logger = logger
    }

    // MARK: - Status

    public func status() -> ModelStatus {
        let reason: String?
        switch model.availability {
        case .available:
            reason = nil
        case .unavailable(let why):
            switch why {
            case .deviceNotEligible: reason = "deviceNotEligible"
            case .appleIntelligenceNotEnabled: reason = "appleIntelligenceNotEnabled"
            case .modelNotReady: reason = "modelNotReady"
            @unknown default: reason = "unknown"
            }
        }
        // The macOS 27 model can also see images (`model.capabilities`
        // contains `.vision`), but this wire does not carry them (see
        // `TranscriptBuilder`), so only what is actually served is advertised.
        let capabilities = ["chat", "streaming", "structured_output", "tools"]
        return ModelStatus(
            available: reason == nil,
            unavailableReason: reason,
            // `contextSize` is back-deployed to macOS 26 but only real on 27;
            // before that it returns a conservative 4096. Measured against
            // `fm serve` on macOS 27.0: 8192.
            contextWindow: model.contextSize,
            capabilities: capabilities
        )
    }

    // MARK: - Completion

    public func complete(_ request: ChatCompletionRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        // `AsyncThrowingStream` is the bridge between "push" code (we call
        // `continuation.yield`) and the "pull" world of `for await`. The
        // producer runs in its own `Task`; when the consumer stops listening,
        // `onTermination` cancels that task, which cancels the generation.
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prepared = try RequestPreparer.prepare(request)
                    for warning in prepared.warnings {
                        logger.info("schema: \(warning)")
                    }
                    try await gate.acquire()
                    defer { Task { await gate.release() } }
                    try await generate(prepared, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ErrorMapper.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func generate(_ prepared: PreparedChat, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws {
        let status = status()
        guard status.available else {
            throw BridgeError.modelUnavailable(status.userMessage)
        }

        let session = LanguageModelSession(model: model, tools: prepared.tools, transcript: prepared.transcript)
        if #available(macOS 27, *) {
            // Keep the entries generated before an error. This is what lets
            // the tool-call path read *every* call the model made out of
            // `session.transcript` after `BridgeTool` throws.
            session.transcriptErrorHandlingPolicy = .preserveTranscript
        }

        var producedText = ""
        var usage: Usage?

        do {
            if let schema = prepared.responseSchema {
                // Structured output. Partial snapshots are valid-so-far JSON
                // rather than growing text (`{"a":["x"]}` → `{"a":["x","y"]}`),
                // so they cannot be streamed as deltas; the finished object
                // is sent once.
                var final: GeneratedContent?
                for try await snapshot in session.streamResponse(to: prepared.prompt, schema: schema, options: prepared.options) {
                    final = snapshot.rawContent
                    if #available(macOS 27, *) { usage = Self.usage(from: snapshot.usage) }
                }
                if let final {
                    producedText = final.jsonString
                    continuation.yield(.contentDelta(producedText))
                }
            } else {
                // Plain text. Snapshots are cumulative (spike check E), so
                // the delta is whatever follows the text already sent. The
                // common-prefix computation also copes, as well as anything
                // can, with a snapshot that rewrote earlier text: the new
                // tail is sent and the old head stays as the client has it.
                for try await snapshot in session.streamResponse(to: prepared.prompt, options: prepared.options) {
                    let full = snapshot.content
                    let shared = full.commonPrefix(with: producedText).count
                    if shared < full.count {
                        continuation.yield(.contentDelta(String(full.dropFirst(shared))))
                    }
                    producedText = full
                    if #available(macOS 27, *) { usage = Self.usage(from: snapshot.usage) }
                }
            }
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ToolCallIntercepted {
            let intercepted = error.underlyingError as! ToolCallIntercepted
            let calls = toolCalls(from: session, fallback: intercepted)
            continuation.yield(.toolCalls(calls))
            if #available(macOS 27, *) { usage = Self.usage(from: session.usage) }
            continuation.yield(.finished(.toolCalls, usage ?? estimatedUsage(prepared, output: calls.map(\.function.arguments).joined())))
            return
        } catch let error as LanguageModelSession.GenerationError {
            if case .refusal = error {
                // OpenAI reports a refusal as a normal completion with
                // `message.refusal` set and `content: null`.
                continuation.yield(.refusal(ErrorMapper.describe(error)))
                if #available(macOS 27, *) { usage = Self.usage(from: session.usage) }
                continuation.yield(.finished(.stop, usage ?? estimatedUsage(prepared, output: "")))
                return
            }
            throw error
        }

        let finalUsage = usage ?? estimatedUsage(prepared, output: producedText)
        let reason: FinishReason
        if let cap = prepared.options.maximumResponseTokens, finalUsage.completionTokens >= cap {
            // The framework does not say why it stopped; hitting the cap is
            // the only case the bridge can recognize.
            reason = .length
        } else {
            reason = .stop
        }
        continuation.yield(.finished(reason, finalUsage))
    }

    // MARK: - Tool calls

    /// Every tool call the model made in the turn that just ended.
    ///
    /// On macOS 27, with `.preserveTranscript`, the session's transcript keeps
    /// the `.toolCalls` entry — with all calls, even when the model asked for
    /// several at once (the first `BridgeTool` to throw ends the turn, but
    /// the entry was written before any tool ran). On macOS 26 only the
    /// intercepted call is known.
    private func toolCalls(from session: LanguageModelSession, fallback: ToolCallIntercepted) -> [ToolCallOutput] {
        if #available(macOS 27, *) {
            for entry in session.transcript.reversed() {
                if case .toolCalls(let calls) = entry, !calls.isEmpty {
                    return calls.enumerated().map { index, call in
                        ToolCallOutput(
                            index: index,
                            id: call.id.isEmpty ? makeToolCallID() : call.id,
                            name: call.toolName,
                            arguments: call.arguments.jsonString
                        )
                    }
                }
            }
        }
        return [ToolCallOutput(index: 0, id: makeToolCallID(), name: fallback.toolName, arguments: fallback.arguments.jsonString)]
    }

    // MARK: - Usage

    @available(macOS 27, *)
    private static func usage(from usage: LanguageModelSession.Usage) -> Usage {
        Usage(promptTokens: usage.input.totalTokenCount, completionTokens: usage.output.totalTokenCount)
    }

    /// macOS 26 has no token accounting on the response. Four characters per
    /// token is the usual rough estimate for English text; it is labeled as
    /// an estimate nowhere on the wire, so treat it as indicative only.
    private func estimatedUsage(_ prepared: PreparedChat, output: String) -> Usage {
        var promptChars = prepared.instructionsText.count + prepared.prompt.count
        for entry in prepared.transcript {
            promptChars += String(describing: entry).count
        }
        return Usage(promptTokens: promptChars / 4, completionTokens: output.count / 4)
    }
}
