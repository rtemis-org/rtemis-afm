// ChatResponse.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation

// The response half of the wire: what the bridge writes back. These are
// `Encodable` only; nothing here is ever parsed by the bridge itself.
//
// The shapes follow OpenAI's `chat.completion` / `chat.completion.chunk`
// objects closely enough for `@ai-sdk/openai-compatible` (which rtemislive
// uses) to consume them. Fields OpenAI marks as always present are always
// written, even when empty, because some clients validate their presence.

/// Why generation ended, in OpenAI's vocabulary.
public enum FinishReason: String, Encodable, Sendable {
    /// The model finished naturally.
    case stop
    /// The response-token cap was reached.
    case length
    /// The model asked for one or more tools to be run.
    case toolCalls = "tool_calls"
    /// Guardrails withheld the output.
    case contentFilter = "content_filter"
}

/// Token accounting for one request.
public struct Usage: Encodable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
    }
}

/// A tool call as the model requested it.
public struct ToolCallOutput: Encodable, Sendable, Equatable {
    /// Position in the `tool_calls` array; streaming clients key deltas by it.
    public var index: Int
    public var id: String
    public var type: String = "function"
    public var function: Function

    public struct Function: Encodable, Sendable, Equatable {
        public var name: String
        /// JSON text — OpenAI ships arguments as a string, not an object.
        public var arguments: String
    }

    public init(index: Int, id: String, name: String, arguments: String) {
        self.index = index
        self.id = id
        self.function = Function(name: name, arguments: arguments)
    }
}

/// The non-streaming `chat.completion` object.
public struct ChatCompletion: Encodable, Sendable {
    public var id: String
    public var object = "chat.completion"
    public var created: Int
    public var model: String
    public var choices: [Choice]
    public var usage: Usage?

    public struct Choice: Encodable, Sendable {
        public var index = 0
        public var message: Message
        public var finishReason: FinishReason

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    public struct Message: Encodable, Sendable {
        public var role = "assistant"
        /// `null` when the turn is a tool call or a refusal.
        public var content: String?
        public var refusal: String?
        public var toolCalls: [ToolCallOutput]?

        enum CodingKeys: String, CodingKey {
            case role, content, refusal
            case toolCalls = "tool_calls"
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            // `content` is always present on the wire; `nil` becomes JSON null.
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(refusal, forKey: .refusal)
            try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        }
    }
}

/// One Server-Sent Event payload in a streaming response.
public struct ChatCompletionChunk: Encodable, Sendable {
    public var id: String
    public var object = "chat.completion.chunk"
    public var created: Int
    public var model: String
    /// Empty on the trailing usage chunk, as OpenAI does it.
    public var choices: [Choice]
    public var usage: Usage?

    public struct Choice: Encodable, Sendable {
        public var index = 0
        public var delta: Delta
        public var finishReason: FinishReason?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(delta, forKey: .delta)
            // Always present: `null` until the final chunk.
            try c.encode(finishReason, forKey: .finishReason)
        }
    }

    /// The incremental part of the message. All fields optional: the first
    /// chunk carries `role`, content chunks carry `content`, tool-call chunks
    /// carry `tool_calls`, and the finish chunk carries nothing.
    public struct Delta: Encodable, Sendable {
        public var role: String?
        public var content: String?
        public var refusal: String?
        public var toolCalls: [ToolCallOutput]?

        enum CodingKeys: String, CodingKey {
            case role, content, refusal
            case toolCalls = "tool_calls"
        }

        public init(role: String? = nil, content: String? = nil, refusal: String? = nil, toolCalls: [ToolCallOutput]? = nil) {
            self.role = role
            self.content = content
            self.refusal = refusal
            self.toolCalls = toolCalls
        }
    }
}

/// `GET /v1/models`.
public struct ModelList: Encodable, Sendable {
    public var object = "list"
    public var data: [ModelEntry]

    public struct ModelEntry: Encodable, Sendable {
        public var id: String
        public var object = "model"
        public var created = 0
        public var ownedBy = "apple"
        /// The bridge's own field: the variant's display name as the
        /// framework reports it, for the picker. `id` stays `afm` so a
        /// stored selection survives macOS updates that rename the model.
        public var name: String
        /// The bridge's own field. rtemislive reads it to decide whether to
        /// offer tools; Apple's `fm serve` has no such field, which is how
        /// the app tells the two servers apart.
        public var capabilities: [String]
        /// Also the bridge's own: the on-device model's context size as the
        /// framework reports it (`SystemLanguageModel.contextSize`).
        public var contextWindow: Int

        enum CodingKeys: String, CodingKey {
            case id, object, created, name, capabilities
            case ownedBy = "owned_by"
            case contextWindow = "context_window"
        }
    }
}

/// `GET /health`.
public struct HealthResponse: Encodable, Sendable {
    public var status = "ok"
    public var version: String
    public var model: Model

    public struct Model: Encodable, Sendable {
        public var id: String
        public var name: String
        /// `available` or `unavailable`.
        public var availability: String
        /// Present only when unavailable: `deviceNotEligible`,
        /// `appleIntelligenceNotEnabled` or `modelNotReady`.
        public var reason: String?
        public var contextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, availability, reason
            case contextWindow = "context_window"
        }
    }
}

/// `{ "error": { message, type, code } }` — the OpenAI error envelope.
public struct ErrorResponse: Encodable, Sendable {
    public var error: Body

    public struct Body: Encodable, Sendable {
        public var message: String
        public var type: String
        public var code: String?
        public var param: String?
    }

    public init(message: String, type: String, code: String? = nil, param: String? = nil) {
        self.error = Body(message: message, type: type, code: code, param: param)
    }
}

// MARK: - Encoding helper

extension JSONEncoder {
    /// The encoder every response goes through. Slashes are left alone
    /// (`https://…` stays readable) and keys keep declaration order-ish
    /// sorting so output is deterministic for tests.
    public static let wire: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()
}

/// Generates an OpenAI-style completion id (`chatcmpl-…`).
public func makeCompletionID() -> String {
    "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
}

/// Generates an OpenAI-style tool-call id (`call_…`).
public func makeToolCallID() -> String {
    "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
}
