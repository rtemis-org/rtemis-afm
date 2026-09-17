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
/// (Xcode 27.0, September 2026). Re-run `afm-spike` after OS/Xcode updates
/// to confirm the assumptions listed in its README still hold.
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
        // `vision` is advertised only when the framework reports it, and
        // rtemislive shows the attach button only then; the on-device model
        // on macOS 27.0 does (spike check V).
        var capabilities = ["chat", "streaming", "structured_output", "tools"]
        if model.capabilities.contains(.vision) { capabilities.append("vision") }
        return ModelStatus(
            available: reason == nil,
            unavailableReason: reason,
            // 8192 on macOS 27.0 (`fm serve` agrees: 7.3k accepted, 10.9k refused).
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
        // Said here rather than left to the framework, whose
        // `unsupportedCapability` would arrive only once generation starts.
        if prepared.hasImages, !model.capabilities.contains(.vision) {
            throw BridgeError.unsupported("this model cannot see images")
        }

        let session = LanguageModelSession(model: model, tools: prepared.tools, transcript: prepared.transcript)
        // Keep the entries generated before an error. This is what lets the
        // tool-call path read *every* call the model made out of
        // `session.transcript` after `BridgeTool` throws.
        session.transcriptErrorHandlingPolicy = .preserveTranscript

        var producedText = ""
        var usage: Usage?
        let prompt = Self.prompt(prepared)

        do {
            if let schema = prepared.responseSchema {
                // Structured output. Partial snapshots are valid-so-far JSON
                // rather than growing text (`{"a":["x"]}` → `{"a":["x","y"]}`),
                // so they cannot be streamed as deltas; the finished object
                // is sent once.
                var final: GeneratedContent?
                for try await snapshot in session.streamResponse(to: prompt, schema: schema, options: prepared.options) {
                    final = snapshot.rawContent
                    usage = Self.usage(from: snapshot.usage)
                }
                if let final {
                    producedText = Self.wireContent(final, open: prepared.responseOpenValues)
                    continuation.yield(.contentDelta(producedText))
                }
            } else {
                // Plain text. Snapshots are cumulative (spike check E), so
                // the delta is whatever follows the text already sent. The
                // common-prefix computation also copes, as well as anything
                // can, with a snapshot that rewrote earlier text: the new
                // tail is sent and the old head stays as the client has it.
                for try await snapshot in session.streamResponse(to: prompt, options: prepared.options) {
                    let full = snapshot.content
                    let shared = full.commonPrefix(with: producedText).count
                    if shared < full.count {
                        continuation.yield(.contentDelta(String(full.dropFirst(shared))))
                    }
                    producedText = full
                    usage = Self.usage(from: snapshot.usage)
                }
            }
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ToolCallIntercepted {
            let intercepted = error.underlyingError as! ToolCallIntercepted
            let calls = toolCalls(from: session, tools: prepared.tools, fallback: intercepted)
            continuation.yield(.toolCalls(calls))
            continuation.yield(.finished(.toolCalls, Self.usage(from: session.usage)))
            return
        } catch let error as LanguageModelError {
            if case .refusal = error {
                // OpenAI reports a refusal as a normal completion with
                // `message.refusal` set and `content: null`. (The framework
                // can also produce an `explanation` by asking the model
                // again; the error's own description is used instead to keep
                // the request to one generation.)
                continuation.yield(.refusal(ErrorMapper.describe(error)))
                continuation.yield(.finished(.stop, Self.usage(from: session.usage)))
                return
            }
            throw error
        }

        let finalUsage = usage ?? Self.usage(from: session.usage)
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

    // MARK: - Prompt

    /// The turn's prompt: its text, then its images. A transcript
    /// attachment and a prompt attachment are two types for one thing, so
    /// the image is handed over as the `CGImage` it was decoded to.
    private static func prompt(_ prepared: PreparedChat) -> Prompt {
        Prompt {
            prepared.prompt
            prepared.promptImages.map { Attachment($0.cgImage, orientation: $0.orientation) }
        }
    }

    // MARK: - Tool calls

    /// Every tool call the model made in the turn that just ended.
    ///
    /// With `.preserveTranscript`, the session's transcript keeps the
    /// `.toolCalls` entry — with all calls, even when the model asked for
    /// several at once (the first `BridgeTool` to throw ends the turn, but
    /// the entry was written before any tool ran). The intercepted call is
    /// the fallback should the entry ever be missing.
    private func toolCalls(from session: LanguageModelSession, tools: [BridgeTool], fallback: ToolCallIntercepted) -> [ToolCallOutput] {
        // Arguments go through the tool's `wireArguments`, which parses the
        // JSON text the model wrote for open objects back into JSON.
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func arguments(_ name: String, _ content: GeneratedContent) -> String {
            byName[name]?.wireArguments(content) ?? content.jsonString
        }
        for entry in session.transcript.reversed() {
            if case .toolCalls(let calls) = entry, !calls.isEmpty {
                return calls.enumerated().map { index, call in
                    ToolCallOutput(
                        index: index,
                        id: call.id.isEmpty ? makeToolCallID() : call.id,
                        name: call.toolName,
                        arguments: arguments(call.toolName, call.arguments)
                    )
                }
            }
        }
        return [ToolCallOutput(index: 0, id: makeToolCallID(), name: fallback.toolName, arguments: arguments(fallback.toolName, fallback.arguments))]
    }

    // MARK: - Structured output

    /// A structured response as the client should see it, with open values
    /// parsed from their JSON text. When the root itself was open
    /// (`json_object`) and the model wrote something that is not a JSON
    /// object, the text is returned as it was written rather than as a
    /// JSON string literal, so the client sees what the model said.
    static func wireContent(_ content: GeneratedContent, open: [OpenValue]) -> String {
        let raw = content.jsonString
        guard !open.isEmpty, let json = try? JSONValue(parsing: raw) else { return raw }
        let restored = OpenValue.restore(json, open: open)
        if open.contains(where: { $0.path.isRoot }), let text = restored.stringValue {
            return text
        }
        return restored.jsonString
    }

    // MARK: - Usage

    /// The framework's own accounting, straight onto the wire.
    private static func usage(from usage: LanguageModelSession.Usage) -> Usage {
        Usage(promptTokens: usage.input.totalTokenCount, completionTokens: usage.output.totalTokenCount)
    }
}
