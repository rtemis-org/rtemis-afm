// SSE.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import NIOCore

/// Server-Sent Events framing, as OpenAI streams chat completions.
///
/// SSE is plain text over a long-lived HTTP response: each event is a
/// `data:` line followed by a blank line. OpenAI sends one JSON chunk per
/// event and ends the stream with the literal `data: [DONE]`.
public enum SSE {
    /// Frames an encodable value as one event.
    public static func event(_ value: some Encodable) throws -> ByteBuffer {
        let data = try JSONEncoder.wire.encode(value)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count + 8)
        buffer.writeString("data: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        return buffer
    }

    /// The terminating event.
    public static let done: ByteBuffer = ByteBuffer(string: "data: [DONE]\n\n")
}

/// Builds the successive `chat.completion.chunk` objects of one response so
/// they share an id, timestamp and model name.
public struct ChunkFactory: Sendable {
    public let id: String
    public let created: Int
    public let model: String

    public init(id: String = makeCompletionID(), created: Int = Int(Date().timeIntervalSince1970), model: String = RtemisAFM.modelID) {
        self.id = id
        self.created = created
        self.model = model
    }

    private func chunk(_ delta: ChatCompletionChunk.Delta, finish: FinishReason? = nil) -> ChatCompletionChunk {
        ChatCompletionChunk(id: id, created: created, model: model, choices: [.init(delta: delta, finishReason: finish)])
    }

    /// The opening chunk: names the role, carries no text.
    public func roleChunk() -> ChatCompletionChunk { chunk(.init(role: "assistant", content: "")) }

    public func contentChunk(_ text: String) -> ChatCompletionChunk { chunk(.init(content: text)) }

    public func refusalChunk(_ text: String) -> ChatCompletionChunk { chunk(.init(refusal: text)) }

    /// All tool calls in one delta. OpenAI streams arguments in fragments;
    /// the bridge has the complete arguments by the time it knows about the
    /// call, and clients accept a whole call in a single delta.
    public func toolCallsChunk(_ calls: [ToolCallOutput]) -> ChatCompletionChunk { chunk(.init(toolCalls: calls)) }

    public func finishChunk(_ reason: FinishReason) -> ChatCompletionChunk { chunk(.init(), finish: reason) }

    /// The trailing usage chunk (`stream_options.include_usage`): no choices.
    public func usageChunk(_ usage: Usage) -> ChatCompletionChunk {
        ChatCompletionChunk(id: id, created: created, model: model, choices: [], usage: usage)
    }
}
