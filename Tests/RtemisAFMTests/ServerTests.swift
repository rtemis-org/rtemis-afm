// ServerTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import XCTest
@testable import RtemisAFM

/// Drives the real router with a scripted backend over a real loopback
/// socket. The in-memory `.router` mode cannot be used: the chat handler
/// relies on Hummingbird's inbound-close watcher, which needs a genuine
/// request-part stream. And because that watcher closes the connection
/// after each chat response, the client must be one that reconnects —
/// `.ahc` (AsyncHTTPClient) does; the single-connection `.live` client
/// does not.
private func post(_ client: some TestClientProtocol, _ body: String, headers: HTTPFields = [:]) async throws -> TestResponse {
    try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers, body: ByteBuffer(string: body))
}

private let simpleRequest = #"{"model":"afm","messages":[{"role":"user","content":"hi"}]}"#

final class ServerTests: XCTestCase {
    private func app(_ backend: FakeBackend = FakeBackend(), verbose: Bool = false) -> Application<RouterResponder<BridgeRequestContext>> {
        BridgeServer.makeApplication(
            configuration: ServerConfiguration(port: 0, verbose: verbose),
            backend: backend,
            logger: Logger(label: "test")
        )
    }


    func testHealthAndModels() async throws {
        try await app().test(.ahc(.http)) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let json = try JSONValue(parsing: String(buffer: response.body))
                XCTAssertEqual(json["status"]?.stringValue, "ok")
                XCTAssertEqual(json["version"]?.stringValue, RtemisAFM.version)
                XCTAssertEqual(json["model"]?["availability"]?.stringValue, "available")
                XCTAssertEqual(json["model"]?["context_window"]?.intValue, 8192)
            }
            try await client.execute(uri: "/v1/models", method: .get) { response in
                let json = try JSONValue(parsing: String(buffer: response.body))
                let model = try XCTUnwrap(json["data"]?.arrayValue?.first)
                XCTAssertEqual(model["id"]?.stringValue, "afm")
                XCTAssertEqual(model["capabilities"], ["chat", "streaming", "structured_output", "tools"])
                XCTAssertEqual(model["owned_by"]?.stringValue, "apple")
            }
        }
    }

    func testHealthWhenUnavailable() async throws {
        var backend = FakeBackend()
        backend.modelStatus = ModelStatus(available: false, unavailableReason: "appleIntelligenceNotEnabled", contextWindow: 4096, capabilities: [])
        try await app(backend).test(.ahc(.http)) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let json = try JSONValue(parsing: String(buffer: response.body))
                XCTAssertEqual(json["model"]?["availability"]?.stringValue, "unavailable")
                XCTAssertEqual(json["model"]?["reason"]?.stringValue, "appleIntelligenceNotEnabled")
            }
        }
    }

    func testProbeContract() async throws {
        try await app().test(.ahc(.http)) { client in
            // Empty body → 400 (rtemislive reads this as "connected").
            let empty = try await client.execute(uri: "/v1/chat/completions", method: .post)
            XCTAssertEqual(empty.status, .badRequest)
            XCTAssertEqual(try JSONValue(parsing: String(buffer: empty.body))["error"]?["code"]?.stringValue, "empty_body")
            // Non-JSON → 400 too.
            let junk = try await post(client, "not json")
            XCTAssertEqual(junk.status, .badRequest)
            XCTAssertEqual(try JSONValue(parsing: String(buffer: junk.body))["error"]?["code"]?.stringValue, "invalid_json")
            // Valid JSON, missing a required field → 400 naming it.
            let missing = try await post(client, #"{"model":"afm"}"#)
            XCTAssertEqual(missing.status, .badRequest)
            XCTAssertTrue(String(buffer: missing.body).contains("messages"))
        }
    }

    func testNonStreamingCompletion() async throws {
        try await app().test(.ahc(.http)) { client in
            let response = try await post(client, simpleRequest)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.headers[.contentType], "application/json")
            let json = try JSONValue(parsing: String(buffer: response.body))
            XCTAssertEqual(json["object"]?.stringValue, "chat.completion")
            let choice = try XCTUnwrap(json["choices"]?.arrayValue?.first)
            XCTAssertEqual(choice["message"]?["content"]?.stringValue, "Hello, world")
            XCTAssertEqual(choice["finish_reason"]?.stringValue, "stop")
            XCTAssertEqual(json["usage"]?["prompt_tokens"]?.intValue, 5)
        }
    }

    func testStreamingCompletion() async throws {
        try await app().test(.ahc(.http)) { client in
            let body = #"{"model":"afm","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}"#
            let response = try await post(client, body)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.headers[.contentType], "text/event-stream")
            let events = sseData(String(buffer: response.body))
            XCTAssertEqual(events.last, "[DONE]")
            let chunks = try events.dropLast().map { try JSONValue(parsing: $0) }
            // role, "Hello", ", world", finish, usage
            XCTAssertEqual(chunks.count, 5)
            XCTAssertEqual(chunks[0]["choices"]?.arrayValue?.first?["delta"]?["role"]?.stringValue, "assistant")
            XCTAssertEqual(chunks[1]["choices"]?.arrayValue?.first?["delta"]?["content"]?.stringValue, "Hello")
            XCTAssertEqual(chunks[3]["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue, "stop")
            XCTAssertEqual(chunks[4]["choices"], [])
            XCTAssertEqual(chunks[4]["usage"]?["total_tokens"]?.intValue, 7)
            // Every chunk shares the completion id.
            XCTAssertEqual(Set(chunks.compactMap { $0["id"]?.stringValue }).count, 1)
        }
    }

    func testStreamingWithoutUsageOmitsUsageChunk() async throws {
        try await app().test(.ahc(.http)) { client in
            let response = try await post(client, #"{"model":"afm","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
            let events = sseData(String(buffer: response.body))
            XCTAssertEqual(events.count, 5)  // role, 2 content, finish, [DONE]
        }
    }

    func testToolCallsInBothModes() async throws {
        var backend = FakeBackend()
        let call = ToolCallOutput(index: 0, id: "call_1", name: "get_weather", arguments: #"{"city":"Paris"}"#)
        backend.events = [.toolCalls([call]), .finished(.toolCalls, nil)]
        try await app(backend).test(.ahc(.http)) { client in
            let plain = try JSONValue(parsing: String(buffer: try await post(client, simpleRequest).body))
            let message = try XCTUnwrap(plain["choices"]?.arrayValue?.first?["message"])
            XCTAssertTrue(message["content"]?.isNull == true)
            XCTAssertEqual(message["tool_calls"]?.arrayValue?.first?["id"]?.stringValue, "call_1")
            XCTAssertEqual(plain["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue, "tool_calls")
            XCTAssertNil(plain["usage"])

            let streamed = try await post(client, #"{"model":"afm","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
            let chunks = try sseData(String(buffer: streamed.body)).dropLast().map { try JSONValue(parsing: $0) }
            XCTAssertEqual(chunks[1]["choices"]?.arrayValue?.first?["delta"]?["tool_calls"]?.arrayValue?.first?["function"]?["arguments"]?.stringValue, #"{"city":"Paris"}"#)
            XCTAssertEqual(chunks[2]["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue, "tool_calls")
        }
    }

    func testRefusal() async throws {
        var backend = FakeBackend()
        backend.events = [.refusal("No."), .finished(.stop, nil)]
        try await app(backend).test(.ahc(.http)) { client in
            let json = try JSONValue(parsing: String(buffer: try await post(client, simpleRequest).body))
            let message = try XCTUnwrap(json["choices"]?.arrayValue?.first?["message"])
            XCTAssertTrue(message["content"]?.isNull == true)
            XCTAssertEqual(message["refusal"]?.stringValue, "No.")
        }
    }

    func testErrorBeforeFirstTokenGetsHonestStatus() async throws {
        var backend = FakeBackend()
        backend.failure = BridgeError(status: 400, type: "invalid_request_error", code: "context_length_exceeded", message: "too long")
        try await app(backend).test(.ahc(.http)) { client in
            for body in [simpleRequest, #"{"model":"afm","stream":true,"messages":[{"role":"user","content":"hi"}]}"#] {
                let response = try await post(client, body)
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(response.headers[.contentType], "application/json")
                XCTAssertEqual(try JSONValue(parsing: String(buffer: response.body))["error"]?["code"]?.stringValue, "context_length_exceeded")
            }
        }
    }

    func testErrorMidStreamIsAnEvent() async throws {
        var backend = FakeBackend()
        backend.failAfter = 1
        try await app(backend).test(.ahc(.http)) { client in
            let response = try await post(client, #"{"model":"afm","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
            XCTAssertEqual(response.status, .ok)
            let events = sseData(String(buffer: response.body))
            XCTAssertEqual(events.last, "[DONE]")
            let errorEvent = try JSONValue(parsing: events[events.count - 2])
            XCTAssertEqual(errorEvent["error"]?["type"]?.stringValue, "server_error")
        }
    }

    func testCORS() async throws {
        try await app().test(.ahc(.http)) { client in
            // Preflight from an allowed origin.
            let preflight = try await client.execute(
                uri: "/v1/chat/completions", method: .options,
                headers: [.origin: "https://live.rtemis.org", .accessControlRequestMethod: "POST", .accessControlRequestHeaders: "content-type, x-custom"]
            )
            XCTAssertEqual(preflight.status, .noContent)
            XCTAssertEqual(preflight.headers[.accessControlAllowOrigin], "https://live.rtemis.org")
            XCTAssertEqual(preflight.headers[.accessControlAllowHeaders], "content-type, x-custom")
            XCTAssertEqual(preflight.headers[.accessControlAllowMethods], "GET, POST, OPTIONS")
            XCTAssertEqual(preflight.headers[.accessControlMaxAge], "600")
            XCTAssertEqual(preflight.headers[.vary], "Origin")

            // Actual request from a dev server on any port.
            let actual = try await post(client, simpleRequest, headers: [.origin: "http://localhost:5173"])
            XCTAssertEqual(actual.headers[.accessControlAllowOrigin], "http://localhost:5173")

            // Disallowed origin: served, but without CORS headers.
            let denied = try await client.execute(uri: "/health", method: .get, headers: [.origin: "https://evil.example"])
            XCTAssertEqual(denied.status, .ok)
            XCTAssertNil(denied.headers[.accessControlAllowOrigin])
            let deniedPreflight = try await client.execute(uri: "/health", method: .options, headers: [.origin: "https://evil.example"])
            XCTAssertEqual(deniedPreflight.status, .noContent)
            XCTAssertNil(deniedPreflight.headers[.accessControlAllowOrigin])

            // The browser's headers that fm serve rejects are ignored here.
            let crossSite = try await post(client, simpleRequest, headers: [.origin: "https://live.rtemis.org", .init("Sec-Fetch-Site")!: "cross-site", .referer: "https://live.rtemis.org/"])
            XCTAssertEqual(crossSite.status, .ok)
        }
    }

    func testExtraAllowedOrigin() async throws {
        let application = BridgeServer.makeApplication(
            configuration: ServerConfiguration(port: 0, allowedOrigins: OriginRule.defaults + [.exact("https://example.org")]),
            backend: FakeBackend(), logger: Logger(label: "test")
        )
        try await application.test(.ahc(.http)) { client in
            let response = try await client.execute(uri: "/health", method: .get, headers: [.origin: "https://example.org"])
            XCTAssertEqual(response.headers[.accessControlAllowOrigin], "https://example.org")
        }
    }
}
