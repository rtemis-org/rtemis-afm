// RequestPreparerTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import FoundationModels
import XCTest
@testable import RtemisAFM

final class RequestPreparerTests: XCTestCase {
    func testDecodesWireFields() throws {
        let request = try decodeRequest("""
        {"model":"afm","messages":[{"role":"user","content":"hi"}],"stream":true,
         "stream_options":{"include_usage":true},"temperature":0.2,"top_p":0.9,"max_completion_tokens":50,
         "tool_choice":{"type":"function","function":{"name":"f"}},"unknown_field":1,
         "response_format":{"type":"json_schema","json_schema":{"name":"x","schema":{"type":"object"}}}}
        """)
        XCTAssertEqual(request.stream, true)
        XCTAssertEqual(request.streamOptions?.includeUsage, true)
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.topP, 0.9)
        XCTAssertEqual(request.effectiveMaxTokens, 50)
        XCTAssertEqual(request.toolChoice, .function(name: "f"))
        XCTAssertEqual(request.responseFormat?.type, "json_schema")
        XCTAssertEqual(request.responseFormat?.jsonSchema?.name, "x")
    }

    func testUnknownModelIs404() throws {
        let request = try decodeRequest(#"{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertThrowsError(try RequestPreparer.prepare(request)) { error in
            XCTAssertEqual((error as? BridgeError)?.status, 404)
            XCTAssertEqual((error as? BridgeError)?.code, "model_not_found")
        }
        // `system` is accepted for parity with Apple's `fm serve`.
        XCTAssertNoThrow(try RequestPreparer.prepare(decodeRequest(#"{"model":"system","messages":[{"role":"user","content":"hi"}]}"#)))
    }

    func testGenerationOptions() throws {
        let request = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"temperature":0.3,"top_k":40,"seed":7,"max_tokens":12}"#)
        let prepared = try RequestPreparer.prepare(request)
        XCTAssertEqual(prepared.options.temperature, 0.3)
        XCTAssertEqual(prepared.options.maximumResponseTokens, 12)
        XCTAssertEqual(prepared.options.samplingMode, .random(top: 40, seed: 7))
        XCTAssertTrue(prepared.tools.isEmpty)
        XCTAssertNil(prepared.responseSchema)
    }

    func testToolsAreConverted() throws {
        let request = try decodeRequest("""
        {"model":"afm","messages":[{"role":"user","content":"hi"}],
         "tools":[{"type":"function","function":{"name":"a","description":"A","parameters":{"type":"object","properties":{"x":{"type":"string","format":"date"}}}}},
                  {"type":"function","function":{"name":"b"}}]}
        """)
        let prepared = try RequestPreparer.prepare(request)
        XCTAssertEqual(prepared.tools.map(\.name), ["a", "b"])
        XCTAssertEqual(prepared.tools[0].description, "A")
        XCTAssertEqual(prepared.warnings.count, 1)
        XCTAssertTrue(prepared.warnings[0].hasPrefix("tool a:"))
        // The instructions entry carries the definitions.
        guard case .instructions(let instructions) = prepared.transcript.first else { return XCTFail() }
        XCTAssertEqual(instructions.toolDefinitions.map(\.name), ["a", "b"])
    }

    func testToolChoiceNoneDropsTools() throws {
        let request = try decodeRequest("""
        {"model":"afm","messages":[{"role":"user","content":"hi"}],"tool_choice":"none",
         "tools":[{"type":"function","function":{"name":"a"}}]}
        """)
        let prepared = try RequestPreparer.prepare(request)
        XCTAssertTrue(prepared.tools.isEmpty)
        XCTAssertTrue(prepared.transcript.isEmpty)
    }

    func testForcedToolKeepsOnlyThatTool() throws {
        let request = try decodeRequest("""
        {"model":"afm","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function","function":{"name":"b"}},
         "tools":[{"type":"function","function":{"name":"a"}},{"type":"function","function":{"name":"b"}}]}
        """)
        let prepared = try RequestPreparer.prepare(request)
        XCTAssertEqual(prepared.tools.map(\.name), ["b"])
        XCTAssertEqual(prepared.options.toolCallingMode, .required)
    }

    func testToolValidation() throws {
        let duplicate = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"tools":[{"function":{"name":"a"}},{"function":{"name":"a"}}]}"#)
        XCTAssertThrowsError(try RequestPreparer.prepare(duplicate)) { XCTAssertEqual(($0 as? BridgeError)?.code, "invalid_tools") }
        let unknownForced = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function","function":{"name":"zzz"}},"tools":[{"function":{"name":"a"}}]}"#)
        XCTAssertThrowsError(try RequestPreparer.prepare(unknownForced)) { XCTAssertEqual(($0 as? BridgeError)?.status, 400) }
        let badSchema = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"tools":[{"function":{"name":"a","parameters":{"type":"banana"}}}]}"#)
        XCTAssertThrowsError(try RequestPreparer.prepare(badSchema)) { XCTAssertEqual(($0 as? BridgeError)?.code, "unsupported_schema") }
    }

    func testResponseFormats() throws {
        let jsonSchema = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"colors","schema":{"type":"object","properties":{"colors":{"type":"array","items":{"type":"string"}}},"required":["colors"]}}}}"#)
        let prepared = try RequestPreparer.prepare(jsonSchema)
        XCTAssertNotNil(prepared.responseSchema)
        XCTAssertEqual(try encoded(prepared.responseSchema!)["required"], ["colors"])

        let jsonObject = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_object"}}"#)
        let objectPrepared = try RequestPreparer.prepare(jsonObject)
        // `json_object` is generated as one string and parsed back at the
        // root (see `OpenValue`), with the instructions asking for an object.
        XCTAssertEqual(try encoded(objectPrepared.responseSchema!)["type"]?.stringValue, "string")
        XCTAssertEqual(objectPrepared.responseOpenValues, [OpenValue(path: ValuePath(), kind: .object)])
        XCTAssertTrue(objectPrepared.instructionsText.contains("JSON object"))

        let missing = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema"}}"#)
        XCTAssertThrowsError(try RequestPreparer.prepare(missing)) { XCTAssertEqual(($0 as? BridgeError)?.code, "invalid_response_format") }

        let unknown = try decodeRequest(#"{"model":"afm","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"xml"}}"#)
        XCTAssertThrowsError(try RequestPreparer.prepare(unknown)) { XCTAssertEqual(($0 as? BridgeError)?.code, "unsupported") }
    }
}
