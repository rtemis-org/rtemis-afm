// BridgeServer.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

/// Settings for one server instance.
public struct ServerConfiguration: Sendable {
    /// Always loopback: the bridge is for the browser on this Mac only.
    public var host = "127.0.0.1"
    public var port = RtemisAFM.defaultPort
    public var allowedOrigins = OriginRule.defaults
    /// One log line per request.
    public var verbose = false

    public init(port: Int = RtemisAFM.defaultPort, allowedOrigins: [OriginRule] = OriginRule.defaults, verbose: Bool = false) {
        self.port = port
        self.allowedOrigins = allowedOrigins
        self.verbose = verbose
    }
}

/// The request context Hummingbird threads through middleware and handlers.
///
/// A custom one only to raise `maxUploadSize`: a long conversation with
/// tool schemas can pass Hummingbird's 2 MB default.
public struct BridgeRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public var maxUploadSize: Int { 32 * 1024 * 1024 }

    public init(source: Source) {
        coreContext = .init(source: source)
    }
}

/// Assembles the HTTP application: routes, CORS, logging.
public enum BridgeServer {
    /// Builds an application ready for `runService()`.
    ///
    /// Kept separate from `run` so tests can drive the same router through
    /// Hummingbird's test client without opening a real port.
    public static func makeApplication(
        configuration: ServerConfiguration,
        backend: any ChatBackend,
        logger: Logger
    ) -> Application<RouterResponder<BridgeRequestContext>> {
        let router = Router(context: BridgeRequestContext.self)
        router.add(middleware: BridgeCORSMiddleware(rules: configuration.allowedOrigins))
        if configuration.verbose {
            router.add(middleware: RequestLogMiddleware(logger: logger))
        }
        Routes.register(on: router, backend: backend, logger: logger, verbose: configuration.verbose)

        var appConfiguration = ApplicationConfiguration(
            address: .hostname(configuration.host, port: configuration.port),
            serverName: "rtemis-afm/\(RtemisAFM.version)"
        )
        appConfiguration.reuseAddress = true
        return Application(
            router: router,
            configuration: appConfiguration,
            logger: logger
        )
    }
}

/// One line per request for `--verbose`: method, path, status, duration.
/// The chat route logs its own line (with token counts) once generation
/// ends, so it is skipped here.
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    let logger: Logger

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let start = ContinuousClock.now
        let response = try await next(request, context)
        if request.uri.path != Routes.chatPath {
            let ms = (ContinuousClock.now - start).milliseconds
            logger.info("\(request.method) \(request.uri.path) \(response.status.code) \(ms)ms")
        }
        return response
    }
}

extension Duration {
    /// Whole milliseconds, for log lines.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Response helpers

extension Response {
    /// A JSON response body from any encodable value.
    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONEncoder.wire.encode(value)) ?? Data("{}".utf8)
        var headers: HTTPFields = [.contentType: "application/json"]
        headers[.contentLength] = String(data.count)
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// The OpenAI error envelope with the error's own status.
    static func error(_ error: BridgeError) -> Response {
        json(error.response, status: HTTPResponse.Status(code: error.status))
    }
}
