// BridgeError.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

/// An error the bridge reports to the client, carrying the HTTP status and
/// the OpenAI `type`/`code` that go with it.
///
/// Every failure the server can name ends up as one of these before it is
/// written out, so the status is always honest — Apple's `fm serve` returns
/// `500` for everything, which is the behavior this type exists to avoid.
public struct BridgeError: Error, Equatable, Sendable {
    public var status: Int
    public var type: String
    public var code: String?
    public var message: String

    public init(status: Int, type: String, code: String? = nil, message: String) {
        self.status = status
        self.type = type
        self.code = code
        self.message = message
    }

    /// The OpenAI error envelope for this error.
    public var response: ErrorResponse {
        ErrorResponse(message: message, type: type, code: code)
    }

    // MARK: Common constructors

    /// `400 invalid_request_error` — the request itself is malformed.
    public static func invalidRequest(_ message: String, code: String? = nil) -> BridgeError {
        BridgeError(status: 400, type: "invalid_request_error", code: code, message: message)
    }

    /// `400 unsupported` — well-formed, but asks for something this wire
    /// cannot do (vision, an unknown `response_format`, …).
    public static func unsupported(_ message: String) -> BridgeError {
        BridgeError(status: 400, type: "invalid_request_error", code: "unsupported", message: message)
    }

    /// `404 model_not_found`.
    public static func modelNotFound(_ model: String) -> BridgeError {
        BridgeError(
            status: 404, type: "invalid_request_error", code: "model_not_found",
            message: "The model \"\(model)\" does not exist. This bridge serves \"\(RtemisAFM.modelID)\"."
        )
    }

    /// `503 model_unavailable` with a reason the user can act on.
    public static func modelUnavailable(_ message: String) -> BridgeError {
        BridgeError(status: 503, type: "model_unavailable", code: "model_unavailable", message: message)
    }

    /// `500 server_error` — the catch-all.
    public static func serverError(_ message: String) -> BridgeError {
        BridgeError(status: 500, type: "server_error", code: nil, message: message)
    }
}
