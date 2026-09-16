// ErrorMapperTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import FoundationModels
import XCTest
@testable import RtemisAFM

final class ErrorMapperTests: XCTestCase {
    func testLanguageModelErrors() throws {
        let overflow = LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long"))
        let mapped = ErrorMapper.map(overflow)
        XCTAssertEqual(mapped.status, 400)
        XCTAssertEqual(mapped.code, "context_length_exceeded")
        XCTAssertTrue(mapped.message.contains("9000"))
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.guardrailViolation(.init(debugDescription: "g"))).type, "content_filter")
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.refusal(.init(explanation: "e", debugDescription: "r"))).code, "refusal")
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "r"))).status, 429)
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "u"))).status, 400)
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.unsupportedCapability(.init(capability: .vision, debugDescription: "v"))).status, 400)
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.timeout(.init(debugDescription: "t"))).status, 504)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.Error.concurrentRequests).status, 429)
        XCTAssertEqual(ErrorMapper.map(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "dl"))).status, 503)
    }

    func testToolCallErrorUnwraps() throws {
        let tool = BridgeTool(name: "t", description: "", parameters: try SchemaConverter.convert(["type": "object"], name: "t").schema)
        let inner = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "r"))
        let wrapped = LanguageModelSession.ToolCallError(tool: tool, underlyingError: inner)
        XCTAssertEqual(ErrorMapper.map(wrapped).status, 429)
    }

    func testPassThroughAndFallback() {
        let own = BridgeError.unsupported("nope")
        XCTAssertEqual(ErrorMapper.map(own), own)
        struct Odd: Error {}
        let odd = ErrorMapper.map(Odd())
        XCTAssertEqual(odd.status, 500)
        // The type name is in the message, so an unmapped error can be found.
        XCTAssertTrue(odd.message.hasPrefix("Odd"), odd.message)
        XCTAssertEqual(ErrorMapper.map(CancellationError()).code, "cancelled")
    }

    /// The framework's internal error for an oversized transcript when tools
    /// are attached (macOS 27.0) is recognized by its message.
    func testInternalContextOverflowIsA400() {
        struct GenerativeError: LocalizedError {
            var errorDescription: String? { "Provided 8,226 tokens, but the maximum allowed is 8,192." }
        }
        let mapped = ErrorMapper.map(GenerativeError())
        XCTAssertEqual(mapped.status, 400)
        XCTAssertEqual(mapped.code, "context_length_exceeded")
        XCTAssertEqual(mapped.message, "Provided 8,226 tokens, but the maximum allowed is 8,192.")
    }
}
