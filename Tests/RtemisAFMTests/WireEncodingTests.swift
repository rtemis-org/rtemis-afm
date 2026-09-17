// WireEncodingTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import XCTest
@testable import RtemisAFM

final class WireEncodingTests: XCTestCase {
    func testCompletionEncodesNullContentForToolCalls() throws {
        let completion = ChatCompletion(
            id: "chatcmpl-1", created: 1, model: "afm",
            choices: [.init(message: .init(content: nil, toolCalls: [.init(index: 0, id: "call_1", name: "f", arguments: "{}")]), finishReason: .toolCalls)],
            usage: Usage(promptTokens: 1, completionTokens: 2)
        )
        let json = try JSONValue(parsing: String(decoding: JSONEncoder.wire.encode(completion), as: UTF8.self))
        let message = try XCTUnwrap(json["choices"]?.arrayValue?.first?["message"])
        XCTAssertTrue(message["content"]?.isNull == true)
        XCTAssertEqual(message["tool_calls"]?.arrayValue?.first?["function"]?["name"]?.stringValue, "f")
        XCTAssertEqual(json["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue, "tool_calls")
        XCTAssertEqual(json["usage"]?["total_tokens"]?.intValue, 3)
    }

    func testChunksAndSSEFraming() throws {
        let factory = ChunkFactory(id: "chatcmpl-x", created: 0, model: "afm")
        let role = String(buffer: try SSE.event(factory.roleChunk()))
        XCTAssertTrue(role.hasPrefix("data: {"))
        XCTAssertTrue(role.hasSuffix("\n\n"))
        XCTAssertTrue(role.contains(#""role":"assistant""#))
        XCTAssertTrue(role.contains(#""finish_reason":null"#))

        let finish = String(buffer: try SSE.event(factory.finishChunk(.stop)))
        XCTAssertTrue(finish.contains(#""finish_reason":"stop""#))

        let usage = String(buffer: try SSE.event(factory.usageChunk(Usage(promptTokens: 1, completionTokens: 1))))
        XCTAssertTrue(usage.contains(#""choices":[]"#))
        XCTAssertEqual(String(buffer: SSE.done), "data: [DONE]\n\n")
    }

    func testImagePartsDecode() throws {
        let request = try decodeRequest("""
        { "model": "afm", "messages": [ { "role": "user", "content": [
            { "type": "text", "text": "What is this?" },
            { "type": "image_url", "image_url": { "url": "data:image/png;base64,AAAA", "detail": "low" } }
        ] } ] }
        """)
        let resolved = try XCTUnwrap(request.messages[0].content).resolved()
        XCTAssertEqual(try resolved.get(), .init(text: "What is this?", imageURLs: ["data:image/png;base64,AAAA"]))
        guard case .parts(let parts) = request.messages[0].content else { return XCTFail("expected parts") }
        XCTAssertEqual(parts[1].imageURL?.detail, "low")
    }

    func testErrorEnvelope() throws {
        let data = try JSONEncoder.wire.encode(BridgeError.modelNotFound("x").response)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(json["error"]?["code"]?.stringValue, "model_not_found")
        XCTAssertEqual(json["error"]?["type"]?.stringValue, "invalid_request_error")
    }
}
