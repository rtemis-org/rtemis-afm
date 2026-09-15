// ErrorMapperTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import FoundationModels
import XCTest
@testable import RtemisAFM

final class ErrorMapperTests: XCTestCase {
    private func context(_ text: String = "x") -> LanguageModelSession.GenerationError.Context {
        .init(debugDescription: text)
    }

    func testGenerationErrors() {
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.exceededContextWindowSize(context())).status, 400)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.exceededContextWindowSize(context())).code, "context_length_exceeded")
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.guardrailViolation(context())).type, "content_filter")
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.unsupportedGuide(context())).status, 400)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.decodingFailure(context())).status, 400)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.assetsUnavailable(context())).status, 503)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.rateLimited(context())).status, 429)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.GenerationError.concurrentRequests(context())).status, 429)
    }

    func testToolCallErrorUnwraps() throws {
        let tool = BridgeTool(name: "t", description: "", parameters: try SchemaConverter.convert(["type": "object"], name: "t").schema)
        let wrapped = LanguageModelSession.ToolCallError(tool: tool, underlyingError: LanguageModelSession.GenerationError.rateLimited(context()))
        XCTAssertEqual(ErrorMapper.map(wrapped).status, 429)
    }

    func testMacOS27Errors() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("LanguageModelError needs macOS 27") }
        let overflow = LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long"))
        let mapped = ErrorMapper.map(overflow)
        XCTAssertEqual(mapped.status, 400)
        XCTAssertTrue(mapped.message.contains("9000"))
        XCTAssertEqual(ErrorMapper.map(LanguageModelError.timeout(.init(debugDescription: "t"))).status, 504)
        XCTAssertEqual(ErrorMapper.map(LanguageModelSession.Error.concurrentRequests).status, 429)
        XCTAssertEqual(ErrorMapper.map(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "dl"))).status, 503)
    }

    func testPassThroughAndFallback() {
        let own = BridgeError.unsupported("nope")
        XCTAssertEqual(ErrorMapper.map(own), own)
        struct Odd: Error {}
        XCTAssertEqual(ErrorMapper.map(Odd()).status, 500)
        XCTAssertEqual(ErrorMapper.map(CancellationError()).code, "cancelled")
    }
}
