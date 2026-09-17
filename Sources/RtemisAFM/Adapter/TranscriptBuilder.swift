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
/// | `user` (text and image parts)     | `.prompt`                                |
/// | `assistant` with `content`        | `.response`                              |
/// | `assistant` with `tool_calls`     | `.toolCalls`                             |
/// | `tool`                            | `.toolOutput`                            |
///
/// The **final** `user` message is not placed in the transcript; it becomes
/// the prompt passed to `respond(to:)`. When the history ends with a `tool`
/// message (the client returning a result) the prompt is empty and the
/// model continues from the transcript — confirmed against macOS 27.0 by
/// `afm-spike` (finding A).
///
/// Images ride on `user` messages only, as on the OpenAI wire: in the
/// history as attachment segments of the `.prompt` entry, on the final
/// message as `promptImages` for the engine to attach (spike check V).
public enum TranscriptBuilder {
    /// The result of building: the history and the current prompt.
    public struct Built: Sendable {
        public var transcript: Transcript
        public var prompt: String
        /// Images on the final `user` message, in wire order.
        public var promptImages: [Transcript.ImageAttachment]
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
        var promptImages: [Transcript.ImageAttachment] = []
        var historyEnd = messages.endIndex
        if messages[lastIndex].role == .user {
            let body = try resolve(messages[lastIndex])
            prompt = body.text
            promptImages = try body.imageURLs.map(ImageDecoder.attachment(from:))
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
                let body = try resolve(message)
                var segments: [Transcript.Segment] = []
                if !body.text.isEmpty || body.imageURLs.isEmpty {
                    segments.append(.text(.init(content: body.text)))
                }
                for url in body.imageURLs {
                    segments.append(.attachment(.init(content: .image(try ImageDecoder.attachment(from: url)))))
                }
                entries.append(.prompt(.init(segments: segments)))
            case .assistant:
                if message.content != nil {
                    let body = try text(of: message)
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

        return Built(transcript: Transcript(entries: entries), prompt: prompt, promptImages: promptImages, instructionsText: instructionsText)
    }

    /// The text of a message that may not carry images (every role but
    /// `user`), or a `400`.
    static func text(of message: ChatMessage) throws(BridgeError) -> String {
        let body = try resolve(message)
        guard body.imageURLs.isEmpty else {
            throw .invalidRequest("image_url parts are accepted in user messages only", code: "invalid_messages")
        }
        return body.text
    }

    /// A message's text and image URLs, or a `400` naming the part this
    /// wire cannot deliver.
    static func resolve(_ message: ChatMessage) throws(BridgeError) -> ChatMessage.Content.Resolved {
        guard let content = message.content else { return .init(text: "", imageURLs: []) }
        switch content.resolved() {
        case .success(let body):
            return body
        case .failure(.unsupported(let type)):
            throw .unsupported("message content part \"\(type)\" is not supported; this wire carries text and image_url parts")
        case .failure(.malformed(let type)):
            throw .invalidRequest("message content part \"\(type)\" is missing its \(type) payload", code: "invalid_messages")
        }
    }
}
