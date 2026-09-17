// TranscriptBuilderTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import FoundationModels
import XCTest
@testable import RtemisAFM

final class TranscriptBuilderTests: XCTestCase {
    func testLastUserMessageBecomesPrompt() throws {
        let messages: [ChatMessage] = [
            .init(role: .system, content: .text("Be brief.")),
            .init(role: .user, content: .text("Hi")),
            .init(role: .assistant, content: .text("Hello!")),
            .init(role: .user, content: .text("How are you?")),
        ]
        let built = try TranscriptBuilder.build(messages: messages)
        XCTAssertEqual(built.prompt, "How are you?")
        XCTAssertEqual(built.instructionsText, "Be brief.")
        let kinds = built.transcript.map(kind)
        XCTAssertEqual(kinds, ["instructions", "prompt", "response"])
    }

    func testSystemMessagesAreConcatenatedFirst() throws {
        let messages: [ChatMessage] = [
            .init(role: .user, content: .text("a")),
            .init(role: .system, content: .text("one")),
            .init(role: .assistant, content: .text("b")),
            .init(role: .developer, content: .text("two")),
            .init(role: .user, content: .text("c")),
        ]
        let built = try TranscriptBuilder.build(messages: messages, extraInstructions: "three")
        XCTAssertEqual(built.instructionsText, "one\n\ntwo\n\nthree")
        XCTAssertEqual(built.transcript.map(kind), ["instructions", "prompt", "response"])
    }

    func testToolRoundTripEntries() throws {
        let messages: [ChatMessage] = [
            .init(role: .user, content: .text("Weather in Paris?")),
            .init(role: .assistant, content: nil, toolCalls: [
                .init(id: "call_1", function: .init(name: "get_weather", arguments: #"{"city":"Paris"}"#))
            ]),
            .init(role: .tool, content: .text(#"{"temp":18}"#), toolCallID: "call_1"),
        ]
        let built = try TranscriptBuilder.build(messages: messages)
        // History ends with a tool result: the prompt is empty and the last
        // user message stays in the transcript.
        XCTAssertEqual(built.prompt, "")
        XCTAssertEqual(built.transcript.map(kind), ["prompt", "toolCalls", "toolOutput"])
        if case .toolCalls(let calls) = built.transcript[1] {
            XCTAssertEqual(calls.first?.id, "call_1")
            XCTAssertEqual(calls.first?.toolName, "get_weather")
            XCTAssertEqual(try calls.first?.arguments.value(String.self, forProperty: "city"), "Paris")
        } else {
            XCTFail("expected toolCalls")
        }
        if case .toolOutput(let output) = built.transcript[2] {
            XCTAssertEqual(output.id, "call_1")
            XCTAssertEqual(output.toolName, "get_weather")
        } else {
            XCTFail("expected toolOutput")
        }
    }

    func testAssistantWithContentAndToolCalls() throws {
        let messages: [ChatMessage] = [
            .init(role: .user, content: .text("go")),
            .init(role: .assistant, content: .text("Sure."), toolCalls: [.init(id: "c", function: .init(name: "f", arguments: "{}"))]),
            .init(role: .tool, content: .text("ok"), toolCallID: "c"),
            .init(role: .user, content: .text("thanks")),
        ]
        let built = try TranscriptBuilder.build(messages: messages)
        XCTAssertEqual(built.transcript.map(kind), ["prompt", "response", "toolCalls", "toolOutput"])
        XCTAssertEqual(built.prompt, "thanks")
    }

    func testTextPartsAreJoined() throws {
        let messages: [ChatMessage] = [
            .init(role: .user, content: .parts([.init(type: "text", text: "a"), .init(type: "text", text: "b")]))
        ]
        XCTAssertEqual(try TranscriptBuilder.build(messages: messages).prompt, "a\nb")
    }

    func testImagesRideOnUserMessages() throws {
        let image = ChatMessage.Content.Part(type: "image_url", imageURL: .init(url: onePixelPNG, detail: "auto"))
        let messages: [ChatMessage] = [
            .init(role: .user, content: .parts([.init(type: "text", text: "Here is a plot."), image])),
            .init(role: .assistant, content: .text("I see it.")),
            .init(role: .user, content: .parts([image, .init(type: "text", text: "And another?")])),
        ]
        let built = try TranscriptBuilder.build(messages: messages)
        XCTAssertEqual(built.prompt, "And another?")
        XCTAssertEqual(built.promptImages.count, 1)
        XCTAssertEqual(built.promptImages.first?.cgImage.width, 1)
        guard case .prompt(let history) = built.transcript[0] else { return XCTFail("expected prompt") }
        XCTAssertEqual(history.segments.count, 2)
        guard case .attachment(let segment) = history.segments[1], case .image(let attachment) = segment.content else {
            return XCTFail("expected an image attachment after the text")
        }
        XCTAssertEqual(attachment.cgImage.height, 1)
    }

    func testImageOnlyUserMessageHasNoEmptyTextSegment() throws {
        let image = ChatMessage.Content.Part(type: "image_url", imageURL: .init(url: onePixelPNG))
        let built = try TranscriptBuilder.build(messages: [
            .init(role: .user, content: .parts([image])),
            .init(role: .assistant, content: .text("A pixel.")),
            .init(role: .user, content: .text("Color?")),
        ])
        guard case .prompt(let history) = built.transcript[0] else { return XCTFail("expected prompt") }
        XCTAssertEqual(history.segments.count, 1)
        if case .text = history.segments[0] { XCTFail("expected only the attachment") }
    }

    func testImagesAreRefusedOutsideUserMessages() {
        let image = ChatMessage.Content.Part(type: "image_url", imageURL: .init(url: onePixelPNG))
        for role in [ChatMessage.Role.system, .assistant] {
            XCTAssertThrowsError(try TranscriptBuilder.build(messages: [
                .init(role: role, content: .parts([image])),
                .init(role: .user, content: .text("x")),
            ]), "\(role)") { error in
                XCTAssertEqual((error as? BridgeError)?.status, 400)
                XCTAssertEqual((error as? BridgeError)?.code, "invalid_messages")
            }
        }
    }

    func testRemoteImageIsUnsupported() {
        let messages: [ChatMessage] = [
            .init(role: .user, content: .parts([.init(type: "image_url", imageURL: .init(url: "https://example.org/a.png"))]))
        ]
        XCTAssertThrowsError(try TranscriptBuilder.build(messages: messages)) { error in
            XCTAssertEqual((error as? BridgeError)?.status, 400)
            XCTAssertEqual((error as? BridgeError)?.code, "unsupported")
        }
    }

    func testUnknownAndMalformedPartsAreRejected() {
        XCTAssertThrowsError(try TranscriptBuilder.build(messages: [
            .init(role: .user, content: .parts([.init(type: "input_audio")]))
        ])) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "unsupported")
        }
        XCTAssertThrowsError(try TranscriptBuilder.build(messages: [
            .init(role: .user, content: .parts([.init(type: "image_url")]))
        ])) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "invalid_messages")
        }
    }

    func testEmptyMessagesAndMissingToolCallID() {
        XCTAssertThrowsError(try TranscriptBuilder.build(messages: []))
        XCTAssertThrowsError(try TranscriptBuilder.build(messages: [.init(role: .tool, content: .text("x"))]))
        XCTAssertThrowsError(try TranscriptBuilder.build(messages: [
            .init(role: .assistant, toolCalls: [.init(id: "c", function: .init(name: "f", arguments: "not json"))]),
            .init(role: .user, content: .text("x")),
        ]))
    }

    func testToolDefinitionsRideOnInstructions() throws {
        let tool = BridgeTool(name: "t", description: "d", parameters: try SchemaConverter.convert(["type": "object", "properties": [:]], name: "t").schema)
        let built = try TranscriptBuilder.build(messages: [.init(role: .user, content: .text("x"))], toolDefinitions: [.init(tool: tool)])
        guard case .instructions(let instructions) = built.transcript[0] else { return XCTFail("expected instructions") }
        XCTAssertEqual(instructions.toolDefinitions.map(\.name), ["t"])
        XCTAssertTrue(instructions.segments.isEmpty)
    }

    private func kind(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .response: "response"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        default: "other"
        }
    }
}
