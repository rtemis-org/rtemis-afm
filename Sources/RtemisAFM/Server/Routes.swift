// Routes.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

/// The three endpoints rtemislive uses.
enum Routes {
    static let chatPath = "/v1/chat/completions"

    static func register(
        on router: Router<BridgeRequestContext>,
        backend: any ChatBackend,
        logger: Logger,
        verbose: Bool
    ) {
        // GET /health — always 200; the body says whether chat can work.
        router.get("/health") { _, _ in
            let status = backend.status()
            return Response.json(HealthResponse(
                version: RtemisAFM.version,
                model: .init(
                    id: RtemisAFM.modelID,
                    availability: status.available ? "available" : "unavailable",
                    reason: status.unavailableReason,
                    contextWindow: status.contextWindow
                )
            ))
        }

        // GET /v1/models — one model, with the bridge's own `capabilities`
        // field that tells rtemislive it may offer tools.
        router.get("/v1/models") { _, _ in
            let status = backend.status()
            return Response.json(ModelList(data: [
                .init(id: RtemisAFM.modelID, capabilities: status.capabilities, contextWindow: status.contextWindow)
            ]))
        }

        let chat = ChatHandler(backend: backend, logger: logger, verbose: verbose)
        router.post(RouterPath(chatPath)) { request, context in
            try await chat.handle(request, context: context)
        }
    }
}

/// `POST /v1/chat/completions`.
struct ChatHandler: Sendable {
    let backend: any ChatBackend
    let logger: Logger
    let verbose: Bool

    func handle(_ request: Request, context: BridgeRequestContext) async throws -> Response {
        // Everything up to the response head runs inside Hummingbird's
        // inbound-close watcher: if the browser gives up while the request
        // is queued or generating, the task is cancelled and the generation
        // with it. The watcher must be handed the *unread* body — it reads
        // the request parts itself to notice the close — which is why the
        // body is collected inside the closure rather than before it.
        //
        // (Streaming responses are written after this returns, outside the
        // watcher; a disconnect there surfaces as a failed write on the next
        // chunk, which ends the generation just the same.)
        let start = ContinuousClock.now
        do {
            return try await request.body.consumeWithCancellationOnInboundClose { body in
                try await self.respond(body: body, request: request, context: context)
            }
        } catch is CancellationError {
            // The client is gone; nobody will read this, but the log should
            // still say what happened.
            return finish(.error(.init(status: 499, type: "server_error", code: "cancelled", message: "Client closed the request")), start: start)
        }
    }

    private func respond(body: RequestBody, request: Request, context: BridgeRequestContext) async throws -> Response {
        let start = ContinuousClock.now

        // Probe contract (spec: rtemis-afm/wire#probe): an empty or non-JSON body is `400` before anything
        // else. rtemislive's settings indicator POSTs an empty body and
        // reads `400` as "connected" (a `403` would mean Apple's `fm serve`).
        let buffer = try await body.collect(upTo: context.maxUploadSize)
        guard buffer.readableBytes > 0 else {
            return finish(.error(.invalidRequest("Request body is empty", code: "empty_body")), start: start)
        }
        let chatRequest: ChatCompletionRequest
        do {
            chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: buffer)
        } catch {
            return finish(.error(.invalidRequest("Malformed request body: \(Self.describe(error))", code: "invalid_json")), start: start)
        }

        // Ask the backend to start. The first event is awaited *before* the
        // response head goes out so that errors raised at the start of
        // generation (context too long, guardrails, model unavailable) get
        // an honest status code instead of a broken stream.
        let events = backend.complete(chatRequest)
        var iterator = events.makeAsyncIterator()
        let first: ChatEvent?
        do {
            first = try await iterator.next()
        } catch {
            return finish(.error(ErrorMapper.map(error)), start: start)
        }
        guard let first else {
            return finish(.error(.serverError("The model produced no output")), start: start)
        }

        if chatRequest.stream == true {
            return streamingResponse(chatRequest: chatRequest, first: first, events: events, start: start)
        }

        // Non-streaming: gather every event into one object.
        do {
            let completion = try await collect(first: first, events: events)
            return finish(.json(completion), start: start, usage: completion.usage)
        } catch {
            return finish(.error(ErrorMapper.map(error)), start: start)
        }
    }

    // MARK: Non-streaming

    private func collect(first: ChatEvent, events: AsyncThrowingStream<ChatEvent, any Error>) async throws -> ChatCompletion {
        var content = ""
        var refusal: String?
        var toolCalls: [ToolCallOutput]?
        var finishReason = FinishReason.stop
        var usage: Usage?

        func absorb(_ event: ChatEvent) {
            switch event {
            case .contentDelta(let text): content += text
            case .toolCalls(let calls): toolCalls = calls
            case .refusal(let text): refusal = text
            case .finished(let reason, let counted):
                finishReason = reason
                usage = counted
            }
        }
        absorb(first)
        for try await event in events { absorb(event) }

        let hasContent = !content.isEmpty || (toolCalls == nil && refusal == nil)
        return ChatCompletion(
            id: makeCompletionID(),
            created: Int(Date().timeIntervalSince1970),
            model: RtemisAFM.modelID,
            choices: [.init(
                message: .init(content: hasContent ? content : nil, refusal: refusal, toolCalls: toolCalls),
                finishReason: finishReason
            )],
            usage: usage
        )
    }

    // MARK: Streaming

    private func streamingResponse(
        chatRequest: ChatCompletionRequest,
        first: ChatEvent,
        events: AsyncThrowingStream<ChatEvent, any Error>,
        start: ContinuousClock.Instant
    ) -> Response {
        let includeUsage = chatRequest.streamOptions?.includeUsage == true
        let factory = ChunkFactory()
        let headers: HTTPFields = [
            .contentType: "text/event-stream",
            .cacheControl: "no-cache",
            .connection: "close",
        ]
        // The body closure runs after the head is sent. It writes chunks as
        // events arrive; if the client closes the connection the next write
        // fails, the loop exits, and dropping `events` cancels the generation.
        let body = ResponseBody { writer in
            var finalUsage: Usage?
            var status = 200
            do {
                try await writer.write(SSE.event(factory.roleChunk()))
                finalUsage = try await self.write(first, factory: factory, includeUsage: includeUsage, to: &writer)
                for try await event in events {
                    if let usage = try await self.write(event, factory: factory, includeUsage: includeUsage, to: &writer) {
                        finalUsage = usage
                    }
                }
            } catch {
                // The head is already out, so the only channel left is an
                // error event in the stream (which OpenAI clients understand).
                let bridgeError = ErrorMapper.map(error)
                status = bridgeError.status
                try? await writer.write(SSE.event(bridgeError.response))
            }
            try? await writer.write(SSE.done)
            try await writer.finish(nil)
            self.log(status: status, start: start, usage: finalUsage)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    /// Writes one event as SSE; returns the usage when the event carried it.
    private func write(_ event: ChatEvent, factory: ChunkFactory, includeUsage: Bool, to writer: inout any ResponseBodyWriter) async throws -> Usage? {
        switch event {
        case .contentDelta(let text):
            try await writer.write(SSE.event(factory.contentChunk(text)))
        case .toolCalls(let calls):
            try await writer.write(SSE.event(factory.toolCallsChunk(calls)))
        case .refusal(let text):
            try await writer.write(SSE.event(factory.refusalChunk(text)))
        case .finished(let reason, let usage):
            try await writer.write(SSE.event(factory.finishChunk(reason)))
            if includeUsage, let usage {
                try await writer.write(SSE.event(factory.usageChunk(usage)))
            }
            return usage
        }
        return nil
    }

    // MARK: Logging

    private func finish(_ response: Response, start: ContinuousClock.Instant, usage: Usage? = nil) -> Response {
        log(status: Int(response.status.code), start: start, usage: usage)
        // The inbound-close watcher leaves the connection unusable for a
        // further request, so Hummingbird closes it after this response.
        // Say so, and clients will not try to reuse it.
        var response = response
        response.headers[.connection] = "close"
        return response
    }

    /// The verbose log line. Never includes prompt or completion text.
    private func log(status: Int, start: ContinuousClock.Instant, usage: Usage?) {
        guard verbose else { return }
        let ms = (ContinuousClock.now - start).milliseconds
        let tokens = usage.map { "\($0.promptTokens)/\($0.completionTokens)" } ?? "-"
        logger.info("POST \(Routes.chatPath) \(status) tokens=\(tokens) \(ms)ms")
    }

    private static func describe(_ error: any Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let ctx):
                return "missing \"\(key.stringValue)\" at \(path(ctx))"
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
                return "\(ctx.debugDescription) at \(path(ctx))"
            @unknown default:
                return String(describing: error)
            }
        }
        return String(describing: error)
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "root" : joined
    }
}
