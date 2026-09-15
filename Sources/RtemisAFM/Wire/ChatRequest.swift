// ChatRequest.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation

// The request half of the OpenAI Chat Completions wire, as the bridge reads
// it. Only the fields the bridge honors are declared; `Decodable` silently
// skips unknown keys, which is how "everything else is ignored, never
// rejected" falls out for free.
//
// Reference: https://platform.openai.com/docs/api-reference/chat/create
// (checked September 2026 — re-check when OpenAI adds fields rtemislive
// starts sending, e.g. new `response_format` types).

/// `POST /v1/chat/completions` body.
public struct ChatCompletionRequest: Decodable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool?
    public var streamOptions: StreamOptions?
    public var temperature: Double?
    public var topP: Double?
    /// Not an OpenAI field, but common on local servers (Ollama, llama.cpp)
    /// and a direct match for `GenerationOptions.SamplingMode.random(top:)`.
    public var topK: Int?
    public var seed: UInt64?
    public var maxTokens: Int?
    public var maxCompletionTokens: Int?
    public var tools: [ToolDefinition]?
    public var toolChoice: ToolChoice?
    public var responseFormat: ResponseFormat?

    // `CodingKeys` maps Swift's camelCase names to the wire's snake_case.
    // Declaring it by hand (rather than using `keyDecodingStrategy`) keeps the
    // mapping explicit and lets `JSONValue` payloads keep their own keys.
    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, seed, tools
        case streamOptions = "stream_options"
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case toolChoice = "tool_choice"
        case responseFormat = "response_format"
    }

    public struct StreamOptions: Decodable, Sendable {
        public var includeUsage: Bool?
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    /// The effective response-token cap: `max_completion_tokens` is the
    /// current OpenAI name, `max_tokens` the legacy one; either is honored.
    public var effectiveMaxTokens: Int? { maxCompletionTokens ?? maxTokens }
}

/// One conversation message. `content` is a string, an array of typed parts,
/// or `null` (assistant messages that only carry `tool_calls`).
public struct ChatMessage: Decodable, Sendable, Equatable {
    public enum Role: String, Decodable, Sendable {
        case system, developer, user, assistant, tool
    }

    public var role: Role
    public var content: Content?
    public var toolCalls: [ToolCall]?
    /// On `tool` messages: which call this is the result of.
    public var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    public init(role: Role, content: Content? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    /// Message content: plain text or a list of parts. The on-device model is
    /// reached over a text-only wire here, so the only part type the bridge
    /// consumes is `text`; anything else (e.g. `image_url`) is reported so the
    /// caller can be told "no vision on this wire".
    public enum Content: Decodable, Sendable, Equatable {
        case text(String)
        case parts([Part])

        public struct Part: Decodable, Sendable, Equatable {
            public var type: String
            public var text: String?
            public init(type: String, text: String? = nil) {
                self.type = type
                self.text = text
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .text(s)
            } else {
                self = .parts(try container.decode([Part].self))
            }
        }

        /// Every text part joined, or `nil` if a non-text part is present.
        /// Returns the offending part type in that case so the error can
        /// name it.
        public func flattenedText() -> Result<String, UnsupportedPart> {
            switch self {
            case .text(let s):
                return .success(s)
            case .parts(let parts):
                var out: [String] = []
                for part in parts {
                    guard part.type == "text", let text = part.text else {
                        return .failure(UnsupportedPart(type: part.type))
                    }
                    out.append(text)
                }
                return .success(out.joined(separator: "\n"))
            }
        }

        public struct UnsupportedPart: Error, Equatable {
            public let type: String
        }
    }

    /// A tool call the assistant made earlier in the conversation.
    public struct ToolCall: Decodable, Sendable, Equatable {
        public var id: String
        public var function: Function

        public struct Function: Decodable, Sendable, Equatable {
            public var name: String
            /// JSON text, as OpenAI sends it (not a parsed object).
            public var arguments: String
            public init(name: String, arguments: String) {
                self.name = name
                self.arguments = arguments
            }
        }

        public init(id: String, function: Function) {
            self.id = id
            self.function = function
        }
    }
}

/// `tools[]` entry: `{ "type": "function", "function": { name, description, parameters } }`.
public struct ToolDefinition: Decodable, Sendable {
    public var type: String?
    public var function: Function

    public struct Function: Decodable, Sendable {
        public var name: String
        public var description: String?
        /// JSON Schema for the arguments, kept as a tree for `SchemaConverter`.
        public var parameters: JSONValue?
        public init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public init(function: Function) {
        self.type = "function"
        self.function = function
    }
}

/// `tool_choice`: either a mode string or a forced function.
public enum ToolChoice: Decodable, Sendable, Equatable {
    case auto
    case none
    case required
    case function(name: String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let mode = try? container.decode(String.self) {
            switch mode {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown tool_choice \"\(mode)\"")
            }
            return
        }
        struct Forced: Decodable {
            struct Function: Decodable { var name: String }
            var function: Function
        }
        self = .function(name: try container.decode(Forced.self).function.name)
    }
}

/// `response_format`: `text`, `json_object`, or `json_schema` with a schema.
public struct ResponseFormat: Decodable, Sendable {
    public var type: String
    public var jsonSchema: JSONSchemaSpec?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    public struct JSONSchemaSpec: Decodable, Sendable {
        public var name: String?
        public var schema: JSONValue?
        public var strict: Bool?
    }
}
