// CORS.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import HTTPTypes
import Hummingbird

/// One entry in the origin allowlist.
///
/// Browsers send an `Origin` header (`scheme://host[:port]`) with every
/// cross-site request; a page can neither change nor omit it. Matching the
/// whole string is the entire access control of this server — there is no
/// authentication, as with Ollama, so the allowlist is what keeps a random
/// web page from using the model.
public enum OriginRule: Sendable, Equatable {
    /// The origin must match exactly (case-insensitive).
    case exact(String)
    /// Any port on this scheme and host, written `http://localhost:*`.
    case anyPort(scheme: String, host: String)

    /// Parses `--allow-origin` text. Returns `nil` for anything that is not
    /// an origin (`scheme://host`, optional `:port` or `:*`).
    public static func parse(_ text: String) -> OriginRule? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = String(trimmed[..<schemeEnd.lowerBound])
        let rest = trimmed[schemeEnd.upperBound...]
        guard !scheme.isEmpty, !rest.isEmpty, !rest.contains("/") else { return nil }
        if rest.hasSuffix(":*") {
            let host = String(rest.dropLast(2))
            guard !host.isEmpty else { return nil }
            return .anyPort(scheme: scheme, host: host)
        }
        return .exact(trimmed)
    }

    public func matches(_ origin: String) -> Bool {
        let candidate = origin.lowercased()
        switch self {
        case .exact(let allowed):
            return candidate == allowed
        case .anyPort(let scheme, let host):
            let prefix = "\(scheme)://\(host)"
            guard candidate.hasPrefix(prefix) else { return false }
            let remainder = candidate.dropFirst(prefix.count)
            if remainder.isEmpty { return true }
            guard remainder.first == ":" else { return false }
            let port = remainder.dropFirst()
            return !port.isEmpty && port.allSatisfy(\.isNumber)
        }
    }

    /// The origins allowed unless `--allow-origin` adds more: the deployed
    /// rtemislive site and any local development server.
    public static let defaults: [OriginRule] = [
        .exact("https://live.rtemis.org"),
        .anyPort(scheme: "http", host: "localhost"),
        .anyPort(scheme: "http", host: "127.0.0.1"),
    ]
}

/// Cross-Origin Resource Sharing for the bridge.
///
/// Hummingbird ships a `CORSMiddleware`, but it cannot express "any port on
/// localhost" or echo the request's `Access-Control-Request-Headers`, and
/// this server's whole purpose is to answer a web page that Apple's own
/// `fm serve` refuses — so the rules are spelled out here in full.
///
/// - Allowed origin: `Access-Control-Allow-Origin: <origin>` and
///   `Vary: Origin` on every response; preflights (`OPTIONS`) get `204`
///   with the allowed methods, the requested headers echoed back, and a
///   ten-minute `Max-Age`.
/// - Disallowed origin: no CORS headers at all. The server still answers,
///   but the browser withholds the response from the page.
/// - No `Origin` header (curl, the CLI's `status`): nothing to do.
///
/// `Sec-Fetch-Site`, `Referer` and friends are deliberately ignored.
public struct BridgeCORSMiddleware<Context: RequestContext>: RouterMiddleware {
    let rules: [OriginRule]

    public init(rules: [OriginRule]) {
        self.rules = rules
    }

    public func isAllowed(_ origin: String) -> Bool {
        rules.contains { $0.matches(origin) }
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let origin = request.headers[.origin] else {
            return try await next(request, context)
        }
        let allowed = isAllowed(origin)

        if request.method == .options {
            // Preflight. Answer here; the route table never sees it.
            var headers: HTTPFields = [:]
            if allowed {
                headers[.accessControlAllowOrigin] = origin
                headers[.accessControlAllowMethods] = "GET, POST, OPTIONS"
                headers[.accessControlAllowHeaders] = request.headers[.accessControlRequestHeaders] ?? "Content-Type"
                headers[.accessControlMaxAge] = "600"
                headers[.vary] = "Origin"
            }
            return Response(status: .noContent, headers: headers)
        }

        var response = try await next(request, context)
        if allowed {
            response.headers[.accessControlAllowOrigin] = origin
            response.headers[.vary] = "Origin"
        }
        return response
    }
}
