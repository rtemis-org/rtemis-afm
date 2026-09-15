// TranscriptBuilder.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels

/// Turns an OpenAI `messages` array into a FoundationModels `Transcript`
/// plus the prompt for the current turn.
///
/// The bridge is stateless: every request carries the whole conversation,
/// and `LanguageModelSession` can be constructed from a `Transcript`, so the
/// history is rebuilt from scratch each time. The mapping:
///
/// | OpenAI message                    | `Transcript.Entry`                       |
/// |-----------------------------------|------------------------------------------|
/// | `system` / `developer` (all)      | one `.instructions`, first               |
/// | `user`                            | `.prompt`                                |
/// | `assistant` with `content`        | `.response`                              |
/// | `assistant` with `tool_calls`     | `.toolCalls`                             |
/// | `tool`                            | `.toolOutput`                            |
///
/// The **final** `user` message is not placed in the transcript; it becomes
/// the prompt passed to `respond(to:)`. When the history ends with a `tool`
/// message (the client returning a result) the prompt is empty and the
/// model continues from the transcript — confirmed against macOS 27.0 by
/// `afm-spike` (finding A).
public enum TranscriptBuilder {
    /// The result of building: the history and the current prompt.
    public struct Built: Sendable {
        public var transcript: Transcript
        public var prompt: String
        /// The instructions text, as folded from the system messages.
        public var instructionsText: String
    }

    /// - Parameters:
    ///   - messages: the request's `messages`, in order.
    ///   - toolDefinitions: definitions for the tools in play, attached to
    ///     the instructions entry (the framework records them there).
    ///   - extraInstructions: text the bridge appends to the system prompt,
    ///     e.g. the JSON-object hint for `response_format: json_object`.
    public static func build(
        messages: [ChatMessage],
        toolDefinitions: [Transcript.ToolDefinition] = [],
        extraInstructions: String? = nil
    ) throws(BridgeError) -> Built {
        guard !messages.isEmpty else {
            throw .invalidRequest("messages must not be empty", code: "invalid_messages")
        }

        // Pass 1: gather instructions. OpenAI allows several system messages
        // anywhere in the list; the framework wants exactly one instructions
        // entry, first. Concatenate in order.
        var instructionParts: [String] = []
        for message in messages where message.role == .system || message.role == .developer {
            instructionParts.append(try text(of: message))
        }
        if let extra = extraInstructions, !extra.isEmpty { instructionParts.append(extra) }
        let instructionsText = instructionParts.joined(separator: "\n\n")

        var entries: [Transcript.Entry] = []
        if !instructionsText.isEmpty || !toolDefinitions.isEmpty {
            let segments: [Transcript.Segment] = instructionsText.isEmpty ? [] : [.text(.init(content: instructionsText))]
            entries.append(.instructions(.init(segments: segments, toolDefinitions: toolDefinitions)))
        }

        // The last message decides what the prompt is.
        let lastIndex = messages.indices.last!
        var prompt = ""
        var historyEnd = messages.endIndex
        if messages[lastIndex].role == .user {
            prompt = try text(of: messages[lastIndex])
            historyEnd = lastIndex
        }

        // Pass 2: the history. `tool` messages need the tool's name, which
        // OpenAI only carries on the earlier `tool_calls`; remember them.
        var toolNamesByCallID: [String: String] = [:]
        for message in messages[..<historyEnd] {
            switch message.role {
            case .system, .developer:
                continue  // already folded into instructions
            case .user:
                entries.append(.prompt(.init(segments: [.text(.init(content: try text(of: message)))])))
            case .assistant:
                if let content = message.content {
                    let body = try flatten(content)
                    if !body.isEmpty {
                        entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: body))])))
                    }
                }
                if let calls = message.toolCalls, !calls.isEmpty {
                    var transcriptCalls: [Transcript.ToolCall] = []
                    for call in calls {
                        toolNamesByCallID[call.id] = call.function.name
                        let arguments: GeneratedContent
                        do {
                            arguments = try GeneratedContent(json: call.function.arguments.isEmpty ? "{}" : call.function.arguments)
                        } catch {
                            throw .invalidRequest(
                                "tool_calls[\(call.id)].function.arguments is not valid JSON: \(error)",
                                code: "invalid_messages")
                        }
                        transcriptCalls.append(.init(id: call.id, toolName: call.function.name, arguments: arguments))
                    }
                    entries.append(.toolCalls(.init(transcriptCalls)))
                }
            case .tool:
                guard let callID = message.toolCallID else {
                    throw .invalidRequest("tool message is missing tool_call_id", code: "invalid_messages")
                }
                let output = try text(of: message)
                entries.append(.toolOutput(.init(
                    id: callID,
                    toolName: toolNamesByCallID[callID] ?? "tool",
                    segments: [.text(.init(content: output))]
                )))
            }
        }

        return Built(transcript: Transcript(entries: entries), prompt: prompt, instructionsText: instructionsText)
    }

    /// The text of a message, or a `400` if it has no text content or
    /// carries a part type this wire cannot deliver (images).
    static func text(of message: ChatMessage) throws(BridgeError) -> String {
        guard let content = message.content else { return "" }
        return try flatten(content)
    }

    static func flatten(_ content: ChatMessage.Content) throws(BridgeError) -> String {
        switch content.flattenedText() {
        case .success(let text):
            return text
        case .failure(let part):
            throw .unsupported("message content part \"\(part.type)\" is not supported; this bridge is text-only (no vision)")
        }
    }
}
