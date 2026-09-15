// SchemaConverter.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels

/// Converts a JSON Schema (as clients send it for tool parameters and
/// `response_format`) into a FoundationModels `GenerationSchema`.
///
/// The framework does not read JSON Schema directly: `GenerationSchema` is
/// `Codable`, but only in its own serialized form (it requires `title` and
/// `x-order` keys and rejects `type: ["string", "null"]`), so decoding a
/// client's schema fails. `DynamicGenerationSchema` is the run-time builder
/// meant for schemas that are not known at compile time, and this converter
/// walks the JSON Schema tree and assembles one.
///
/// Coverage (September 2026):
///
/// | JSON Schema                         | Result                                     |
/// |-------------------------------------|--------------------------------------------|
/// | `object` + `properties`/`required`  | named object; unlisted properties optional |
/// | `array` + `items`, `min/maxItems`   | `arrayOf`                                  |
/// | `string`, `enum`, `const`           | `String`, or a named choice list           |
/// | `number`, `integer`, `min/maximum`  | `Double` / `Int` with range guides         |
/// | `boolean`, `null`                   | `Bool`, `.null`                            |
/// | `type: [T, "null"]`                 | `T`, and the property becomes optional     |
/// | `anyOf` / `oneOf`                   | `anyOf` (oneOf treated as anyOf, warned)   |
/// | `$ref: "#/$defs/X"`                 | reference into `dependencies`, or inlined  |
/// | `description`                       | passed through — it steers the model       |
///
/// Everything else (`pattern`, `format`, `additionalProperties: {…}`,
/// `allOf` with several members, `if`/`then`, …) is ignored and reported in
/// the returned `warnings`, never a failure: the schema still constrains
/// what it can. A schema with no usable shape at all throws
/// `SchemaConversionError`.
///
/// **Future updates:** `DynamicGenerationSchema` gains initializers over
/// time (compare the `extension DynamicGenerationSchema` block in the SDK's
/// `FoundationModels.swiftinterface`). `pattern` could map to
/// `GenerationGuide.pattern(Regex)` once the regex dialects are reconciled.
public struct SchemaConverter {
    /// A converted schema plus the keywords that had to be ignored.
    public struct Result {
        public var schema: GenerationSchema
        public var warnings: [String]
    }

    public struct SchemaConversionError: Error, CustomStringConvertible, Equatable {
        public var path: String
        public var reason: String
        public var description: String { "\(path): \(reason)" }
    }

    /// Converts `json` into a `GenerationSchema` whose root is named `name`.
    public static func convert(_ json: JSONValue, name: String) throws -> Result {
        var converter = SchemaConverter(definitions: Self.definitions(in: json))
        let root = try converter.convert(json, name: name, path: "$")
        // Definitions referenced by name are collected while walking; the
        // framework resolves `referenceTo` against this list.
        let schema = try GenerationSchema(root: root, dependencies: Array(converter.dependencies.values))
        return Result(schema: schema, warnings: converter.warnings)
    }

    // MARK: - State

    /// `$defs` / `definitions` from the root, keyed by definition name.
    private let definitions: [String: JSONValue]
    /// Named schemas to hand the framework as `dependencies`.
    private var dependencies: [String: DynamicGenerationSchema] = [:]
    /// Definitions currently being converted — a cycle guard for inlining.
    private var inlining: Set<String> = []
    private var warnings: [String] = []

    private init(definitions: [String: JSONValue]) {
        self.definitions = definitions
    }

    private static func definitions(in root: JSONValue) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in ["$defs", "definitions"] {
            if let defs = root[key]?.objectValue { out.merge(defs, uniquingKeysWith: { a, _ in a }) }
        }
        return out
    }

    private mutating func warn(_ path: String, _ message: String) {
        warnings.append("\(path): \(message)")
    }

    // MARK: - Walk

    /// Converts one schema node. `name` is what the framework will call it
    /// (only objects and choice lists carry names); `path` is for messages.
    private mutating func convert(_ node: JSONValue, name: String, path: String) throws -> DynamicGenerationSchema {
        guard let object = node.objectValue else {
            // `true` / `{}` mean "anything". There is no "anything" in guided
            // generation; a free string is the least constraining choice.
            if node.boolValue == true || node.isNull {
                warn(path, "unconstrained schema; using string")
                return DynamicGenerationSchema(type: String.self)
            }
            throw SchemaConversionError(path: path, reason: "schema must be an object")
        }

        if let ref = object["$ref"]?.stringValue {
            return try resolveReference(ref, path: path)
        }

        let description = object["description"]?.stringValue

        // Keywords the converter knows about and does not need to warn on.
        let known: Set<String> = [
            "type", "properties", "required", "items", "minItems", "maxItems", "enum", "const",
            "description", "title", "anyOf", "oneOf", "allOf", "minimum", "maximum", "$defs",
            "definitions", "$schema", "$id", "$comment", "default", "examples", "additionalProperties",
            "nullable",
        ]
        for key in object.keys.sorted() where !known.contains(key) {
            warn(path, "ignored keyword \"\(key)\"")
        }
        if let ap = object["additionalProperties"], ap.objectValue != nil {
            warn(path, "ignored additionalProperties schema")
        }

        // Composition first: a node with `anyOf` rarely has a useful `type`.
        if let choices = object["anyOf"]?.arrayValue ?? object["oneOf"]?.arrayValue {
            if object["anyOf"] == nil { warn(path, "oneOf treated as anyOf") }
            return try convertChoices(choices, name: name, description: description, path: path)
        }
        if let all = object["allOf"]?.arrayValue {
            guard all.count == 1 else {
                throw SchemaConversionError(path: path, reason: "allOf with \(all.count) members is not supported")
            }
            return try convert(all[0], name: name, path: path + "/allOf/0")
        }

        // `enum` / `const` describe a choice list regardless of `type`.
        if let values = object["enum"]?.arrayValue {
            let strings = values.compactMap { $0.stringValue }
            guard strings.count == values.count, !strings.isEmpty else {
                warn(path, "non-string enum values; using string")
                return DynamicGenerationSchema(type: String.self)
            }
            return DynamicGenerationSchema(name: name, description: description, anyOf: strings)
        }
        if let constant = object["const"]?.stringValue {
            return DynamicGenerationSchema(name: name, description: description, anyOf: [constant])
        }

        // `type` may be a string or a list; `"null"` in a list is handled by
        // the caller (it makes a property optional), so drop it here.
        let types = Self.types(of: object)
        let concrete = types.filter { $0 != "null" }

        if concrete.count > 1 {
            // A union of primitive types: express it as a choice between
            // single-typed copies of this node.
            let variants = try concrete.map { type -> DynamicGenerationSchema in
                var copy = object
                copy["type"] = .string(type)
                return try convert(.object(copy), name: "\(name)_\(type)", path: path + "[\(type)]")
            }
            return DynamicGenerationSchema(name: name, description: description, anyOf: variants)
        }

        // Infer the type when it is missing but the shape is obvious.
        let type = concrete.first ?? (object["properties"] != nil ? "object" : object["items"] != nil ? "array" : nil)

        switch type {
        case "object":
            return try convertObject(object, name: name, description: description, path: path)
        case "array":
            return try convertArray(object, name: name, path: path)
        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            var guides: [GenerationGuide<Int>] = []
            if let min = object["minimum"]?.intValue { guides.append(.minimum(min)) }
            if let max = object["maximum"]?.intValue { guides.append(.maximum(max)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case "number":
            var guides: [GenerationGuide<Double>] = []
            if let min = object["minimum"]?.doubleValue { guides.append(.minimum(min)) }
            if let max = object["maximum"]?.doubleValue { guides.append(.maximum(max)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "null":
            return nullSchema(path)
        case nil:
            if types == ["null"] { return nullSchema(path) }
            warn(path, "no type; using string")
            return DynamicGenerationSchema(type: String.self)
        default:
            throw SchemaConversionError(path: path, reason: "unknown type \"\(type!)\"")
        }
    }

    private mutating func convertObject(
        _ object: [String: JSONValue], name: String, description: String?, path: String
    ) throws -> DynamicGenerationSchema {
        let properties = object["properties"]?.objectValue ?? [:]
        let required = object["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        // JSON objects are unordered once parsed, but property order affects
        // how the model generates. Required properties keep the order the
        // schema listed them in; the rest follow alphabetically.
        var ordered = required.filter { properties[$0] != nil }
        ordered += properties.keys.filter { !required.contains($0) }.sorted()

        var out: [DynamicGenerationSchema.Property] = []
        for key in ordered {
            let node = properties[key]!
            let childPath = "\(path)/\(key)"
            // Nested named schemas need unique names across the whole
            // document, so children are named by their path.
            let childName = "\(name)_\(key)"
            let schema = try convert(node, name: childName, path: childPath)
            let nullable = Self.isNullable(node) || node["nullable"]?.boolValue == true
            out.append(DynamicGenerationSchema.Property(
                name: key,
                description: node["description"]?.stringValue,
                schema: schema,
                isOptional: !required.contains(key) || nullable
            ))
        }
        return DynamicGenerationSchema(name: name, description: description, properties: out)
    }

    private mutating func convertArray(_ object: [String: JSONValue], name: String, path: String) throws -> DynamicGenerationSchema {
        let items: DynamicGenerationSchema
        if let itemsNode = object["items"] {
            items = try convert(itemsNode, name: "\(name)_item", path: path + "/items")
        } else {
            warn(path, "array without items; using string items")
            items = DynamicGenerationSchema(type: String.self)
        }
        return DynamicGenerationSchema(
            arrayOf: items,
            minimumElements: object["minItems"]?.intValue,
            maximumElements: object["maxItems"]?.intValue
        )
    }

    private mutating func convertChoices(
        _ choices: [JSONValue], name: String, description: String?, path: String
    ) throws -> DynamicGenerationSchema {
        // `anyOf: [{type: X}, {type: "null"}]` is another spelling of
        // nullable; the property-level handling covers it, so just drop null.
        let nonNull = choices.filter { !Self.types(of: $0.objectValue ?? [:]).elementsEqual(["null"]) }
        guard !nonNull.isEmpty else { return nullSchema(path) }
        if nonNull.count == 1 {
            return try convert(nonNull[0], name: name, path: path + "/anyOf/0")
        }
        // Every branch that is a plain string enum can be merged into one
        // choice list, which reads better to the model than nested options.
        let allEnums = nonNull.allSatisfy { $0["enum"]?.arrayValue != nil || $0["const"]?.stringValue != nil }
        if allEnums {
            var values: [String] = []
            for branch in nonNull {
                values += branch["enum"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                if let c = branch["const"]?.stringValue { values.append(c) }
            }
            return DynamicGenerationSchema(name: name, description: description, anyOf: values)
        }
        let variants = try nonNull.enumerated().map { index, branch in
            try convert(branch, name: "\(name)_\(index)", path: "\(path)/anyOf/\(index)")
        }
        return DynamicGenerationSchema(name: name, description: description, anyOf: variants)
    }

    // MARK: - References

    /// `$ref` support. Only local references into `$defs`/`definitions` are
    /// understood. A definition that produces a *named* schema (object or
    /// choice list) is registered once as a dependency and referenced by
    /// name — which also makes recursive schemas work. Anything else (a
    /// bare string or array definition has no name to reference) is inlined.
    private mutating func resolveReference(_ ref: String, path: String) throws -> DynamicGenerationSchema {
        let prefixes = ["#/$defs/", "#/definitions/"]
        guard let prefix = prefixes.first(where: { ref.hasPrefix($0) }) else {
            throw SchemaConversionError(path: path, reason: "unsupported $ref \"\(ref)\" (only #/$defs/… is supported)")
        }
        let defName = String(ref.dropFirst(prefix.count))
        guard let definition = definitions[defName] else {
            throw SchemaConversionError(path: path, reason: "$ref to undefined \"\(defName)\"")
        }
        let name = "def_" + defName.replacingOccurrences(of: "/", with: "_")

        if dependencies[name] != nil || inlining.contains(name) {
            // Already registered, or being registered further up the stack
            // (recursion): a reference by name is what the framework wants.
            return DynamicGenerationSchema(referenceTo: name)
        }

        inlining.insert(name)
        defer { inlining.remove(name) }
        let converted = try convert(definition, name: name, path: "#/$defs/\(defName)")

        if Self.isNameable(definition) {
            dependencies[name] = converted
            return DynamicGenerationSchema(referenceTo: name)
        }
        return converted
    }

    /// Whether converting `node` yields a schema that carries a name (and can
    /// therefore be referenced): objects and choice lists do; scalars and
    /// arrays do not.
    private static func isNameable(_ node: JSONValue) -> Bool {
        guard let object = node.objectValue else { return false }
        if object["anyOf"] != nil || object["oneOf"] != nil || object["enum"] != nil || object["const"] != nil { return true }
        let types = types(of: object).filter { $0 != "null" }
        return types == ["object"] || (types.isEmpty && object["properties"] != nil)
    }

    // MARK: - Helpers

    /// A schema that only admits `null`. `DynamicGenerationSchema.null` is
    /// macOS 26.4+; older systems get a string and a warning.
    private mutating func nullSchema(_ path: String) -> DynamicGenerationSchema {
        if #available(macOS 26.4, *) { return .null }
        warn(path, "null type needs macOS 26.4; using string")
        return DynamicGenerationSchema(type: String.self)
    }

    /// The `type` keyword normalized to a list.
    private static func types(of object: [String: JSONValue]) -> [String] {
        if let single = object["type"]?.stringValue { return [single] }
        return object["type"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    /// `type: [..., "null"]` or `anyOf` with a null branch.
    private static func isNullable(_ node: JSONValue) -> Bool {
        guard let object = node.objectValue else { return false }
        if types(of: object).contains("null") { return true }
        let branches = object["anyOf"]?.arrayValue ?? object["oneOf"]?.arrayValue ?? []
        return branches.contains { types(of: $0.objectValue ?? [:]) == ["null"] }
    }
}
