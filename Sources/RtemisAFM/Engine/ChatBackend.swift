// ChatBackend.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

/// What the HTTP layer needs from "the thing that generates". The real
/// implementation is `FoundationModelsBackend`; tests plug in a fake so the
/// server can be exercised on a machine without Apple Intelligence.
public protocol ChatBackend: Sendable {
    /// Current model status, for `/health` and `/v1/models`.
    func status() -> ModelStatus

    /// Runs one chat completion. The stream yields incremental events and
    /// ends with exactly one `.finished`; errors are `BridgeError`s.
    /// Cancelling the consuming task cancels the generation.
    func complete(_ request: ChatCompletionRequest) -> AsyncThrowingStream<ChatEvent, any Error>
}

/// One step of a completion, independent of whether the client asked for
/// SSE or a single JSON object; the server renders both from this.
public enum ChatEvent: Sendable, Equatable {
    /// New text since the previous event.
    case contentDelta(String)
    /// The model asked for tools to be run. Terminal apart from `.finished`.
    case toolCalls([ToolCallOutput])
    /// The model declined; the text is the explanation for `message.refusal`.
    case refusal(String)
    /// Generation ended. `usage` is `nil` only when nothing could be counted.
    case finished(FinishReason, Usage?)
}

/// The on-device model's state, as reported to clients.
public struct ModelStatus: Sendable, Equatable {
    public var available: Bool
    /// `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`,
    /// or `nil` when available.
    public var unavailableReason: String?
    /// The context window in tokens, as the framework reports it.
    public var contextWindow: Int
    /// Capabilities to advertise on `/v1/models`.
    public var capabilities: [String]

    public init(available: Bool, unavailableReason: String? = nil, contextWindow: Int, capabilities: [String]) {
        self.available = available
        self.unavailableReason = unavailableReason
        self.contextWindow = contextWindow
        self.capabilities = capabilities
    }

    /// A sentence the user can act on, for the CLI banner and `503`s.
    public var userMessage: String {
        switch unavailableReason {
        case nil:
            return "Apple Intelligence is available."
        case "appleIntelligenceNotEnabled":
            return "Apple Intelligence is off — turn it on in System Settings ▸ Apple Intelligence & Siri."
        case "deviceNotEligible":
            return "This Mac isn't eligible for Apple Intelligence (Apple silicon is required)."
        case "modelNotReady":
            return "The model is still downloading; try again shortly."
        case let other?:
            return "The model is unavailable (\(other))."
        }
    }
}
