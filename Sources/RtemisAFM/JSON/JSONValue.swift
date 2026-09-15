// JSONValue.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation

/// A JSON document as a Swift value.
///
/// Most of the OpenAI wire has a fixed shape and is decoded straight into
/// `Codable` structs (see `Wire/`). Two parts are open-shaped: JSON Schemas
/// (tool parameters, `response_format`) and tool-call arguments. Those are
/// held as a `JSONValue` tree and walked by hand.
///
/// For a developer new to Swift: an `indirect enum` is a sum type whose cases
/// may contain values of the enum's own type (here, arrays and objects of
/// `JSONValue`). `indirect` tells the compiler to box those recursive
/// payloads. The `ExpressibleBy…Literal` conformances let tests write
/// `["type": "string"]` and have it become a `JSONValue` automatically.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Convenience accessors

extension JSONValue {
    /// The value under `key` when this is an object, otherwise `nil`.
    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// The string payload, or `nil` for any other case.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The numeric payload, or `nil` for any other case.
    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The numeric payload when it is a whole number, otherwise `nil`.
    public var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < Double(Int.max) else { return nil }
        return Int(n)
    }

    /// The boolean payload, or `nil` for any other case.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The array payload, or `nil` for any other case.
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// The object payload, or `nil` for any other case.
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// `true` for `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Codable
//
// `Codable` is Swift's built-in serialization protocol pair (`Encodable` and
// `Decodable`). Foundation's `JSONDecoder` drives the `init(from:)` below by
// handing us a "container" that we probe for each JSON type in turn.

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            // Encode whole numbers without a fractional part so `8192.0`
            // does not leak into the wire as `8192.0`.
            if n.rounded() == n, abs(n) < 1e15 { try container.encode(Int64(n)) } else { try container.encode(n) }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Text round trip

extension JSONValue {
    /// Parses a JSON document from text.
    public init(parsing text: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Serializes to compact JSON text. Keys are sorted so output is stable,
    /// which matters for tests and for logs.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a `JSONValue` cannot fail: every case maps to a JSON type.
        let data = (try? encoder.encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
