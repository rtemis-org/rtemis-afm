// BridgeTool.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import FoundationModels

/// Thrown by `BridgeTool.call` to hand a tool call back to the HTTP client
/// instead of running anything locally.
///
/// The framework wraps it in `LanguageModelSession.ToolCallError`, which the
/// engine catches. Public only so `afm-spike` can inspect it.
public struct ToolCallIntercepted: Error, Sendable {
    public let toolName: String
    public let arguments: GeneratedContent
}

/// A `Tool` that stands in for a function the *client* will run.
///
/// The two tool loops point in opposite directions. OpenAI's client runs
/// the tool itself and posts the result back in a new request;
/// FoundationModels calls `Tool.call(arguments:)` inside the process and
/// waits for the answer. This type bridges them without keeping a session
/// alive across HTTP requests:
///
/// 1. `call` does no work. It throws `ToolCallIntercepted` carrying the
///    arguments the model produced.
/// 2. The engine catches the resulting `ToolCallError`, reads every call the
///    model made from the session transcript, and answers the HTTP request
///    with `finish_reason: "tool_calls"`.
/// 3. The client runs the tool and posts the whole history back, now ending
///    in `assistant.tool_calls` + `tool`; `TranscriptBuilder` turns those
///    into `.toolCalls` / `.toolOutput` entries and the model continues.
///
/// `Arguments` is `GeneratedContent` — the framework's untyped JSON-like
/// value — because the argument shape is only known at run time, from the
/// JSON Schema the client sent. `Output` is `String` because the protocol
/// needs *some* output type even though `call` never returns.
public struct BridgeTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    /// Where in `arguments` the model writes JSON text that must be parsed
    /// back before the call reaches the client (see `OpenValue`).
    public let openValues: [OpenValue]

    public init(name: String, description: String, parameters: GenerationSchema, openValues: [OpenValue] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.openValues = openValues
    }

    /// The model's arguments as the client should see them: the
    /// framework's JSON with every open value parsed from its string.
    public func wireArguments(_ arguments: GeneratedContent) -> String {
        let raw = arguments.jsonString
        guard !openValues.isEmpty, let json = try? JSONValue(parsing: raw) else { return raw }
        return OpenValue.restore(json, open: openValues).jsonString
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        throw ToolCallIntercepted(toolName: name, arguments: arguments)
    }
}
