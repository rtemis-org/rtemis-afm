// SchemaConverterTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import XCTest
@testable import RtemisAFM

/// The converter is exercised through the framework's own encoding of the
/// result: if `GenerationSchema(root:dependencies:)` accepted the tree and
/// the encoded form names the right properties, the model will be
/// constrained as intended. (Whether the model *generates* well against it
/// is what `afm-spike` checks on a real machine.) The framework encodes
/// nested named schemas as `$ref`s into `$defs`; `encoded()` inlines them
/// so assertions can follow the natural path.
final class SchemaConverterTests: XCTestCase {
    func testObjectWithRequiredAndEnum() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "city": ["type": "string", "description": "City name"],
                "unit": ["type": "string", "enum": ["c", "f"]],
                "days": ["type": "integer", "minimum": 1, "maximum": 7],
            ],
            "required": ["city"],
        ]
        let result = try SchemaConverter.convert(schema, name: "get_weather")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        let json = try encoded(result.schema)
        XCTAssertEqual(json["type"]?.stringValue, "object")
        XCTAssertEqual(json["required"], ["city"])
        XCTAssertEqual(json["properties"]?["city"]?["description"]?.stringValue, "City name")
        XCTAssertEqual(json["properties"]?["unit"]?["enum"], ["c", "f"])
        XCTAssertEqual(json["properties"]?["days"]?["type"]?.stringValue, "integer")
        // Required properties come first, then the rest alphabetically.
        XCTAssertEqual(json["x-order"], ["city", "days", "unit"])
    }

    func testArraysAndNesting() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "steps": [
                    "type": "array", "minItems": 1,
                    "items": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
                ]
            ],
            "required": ["steps"],
        ]
        let json = try encoded(try SchemaConverter.convert(schema, name: "plan").schema)
        XCTAssertEqual(json["properties"]?["steps"]?["type"]?.stringValue, "array")
        XCTAssertEqual(json["properties"]?["steps"]?["minItems"]?.intValue, 1)
        XCTAssertEqual(json["properties"]?["steps"]?["items"]?["required"], ["id"])
    }

    func testNullableTypeBecomesOptional() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["outcome": ["type": ["string", "null"]]],
            "required": ["outcome"],
        ]
        let json = try encoded(try SchemaConverter.convert(schema, name: "t").schema)
        XCTAssertEqual(json["properties"]?["outcome"]?["type"]?.stringValue, "string")
        // Required on the wire, but nullable — the model may leave it out.
        XCTAssertNotEqual(json["required"], ["outcome"])
    }

    func testAnyOfOfEnumsMerges() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["mode": ["anyOf": [["enum": ["a", "b"]], ["const": "c"]]]],
        ]
        let json = try encoded(try SchemaConverter.convert(schema, name: "t").schema)
        XCTAssertEqual(json["properties"]?["mode"]?["enum"], ["a", "b", "c"])
    }

    func testAnyOfOfObjects() throws {
        let schema: JSONValue = [
            "anyOf": [
                ["type": "object", "properties": ["a": ["type": "string"]], "required": ["a"]],
                ["type": "object", "properties": ["b": ["type": "number"]], "required": ["b"]],
            ]
        ]
        let json = try encoded(try SchemaConverter.convert(schema, name: "either").schema)
        XCTAssertEqual(json["anyOf"]?.arrayValue?.count, 2)
    }

    func testRefIntoDefs() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["config": ["$ref": "#/$defs/Config"], "tag": ["$ref": "#/$defs/Tag"]],
            "required": ["config"],
            "$defs": [
                "Config": ["type": "object", "properties": ["algorithm": ["type": "string"]], "required": ["algorithm"]],
                "Tag": ["type": "string"],
            ],
        ]
        let json = try encoded(try SchemaConverter.convert(schema, name: "root").schema)
        // A named definition is referenced; the encoder inlines it back.
        XCTAssertEqual(json["properties"]?["config"]?["required"], ["algorithm"])
        // A scalar definition is inlined by the converter.
        XCTAssertEqual(json["properties"]?["tag"]?["type"]?.stringValue, "string")
    }

    func testRecursiveRef() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["name": ["type": "string"], "children": ["type": "array", "items": ["$ref": "#/$defs/Node"]]],
            "$defs": ["Node": ["type": "object", "properties": ["name": ["type": "string"], "children": ["type": "array", "items": ["$ref": "#/$defs/Node"]]]]],
        ]
        XCTAssertNoThrow(try SchemaConverter.convert(schema, name: "tree"))
    }

    func testUnsupportedKeywordsWarnButConvert() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["email": ["type": "string", "format": "email", "pattern": "^.+@.+$"]],
            "additionalProperties": ["type": "string"],
        ]
        let result = try SchemaConverter.convert(schema, name: "t")
        XCTAssertEqual(result.warnings.count, 3, "\(result.warnings)")
        XCTAssertTrue(result.warnings.contains { $0.contains("format") })
        XCTAssertTrue(result.warnings.contains { $0.contains("additionalProperties") })
    }

    func testUnresolvableSchemaThrows() {
        XCTAssertThrowsError(try SchemaConverter.convert(["type": "object", "properties": ["x": ["$ref": "#/$defs/Missing"]]], name: "t"))
        XCTAssertThrowsError(try SchemaConverter.convert(["allOf": [["type": "string"], ["type": "number"]]], name: "t"))
        XCTAssertThrowsError(try SchemaConverter.convert(["type": "banana"], name: "t"))
    }

    /// An object with no `properties` becomes JSON text in a string, with
    /// the hint on the property that holds it, and its path is recorded so
    /// the engine can parse it back. Arrays of open objects record one path
    /// that covers every element.
    func testOpenObjectsBecomeJSONText() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "config": [
                    "type": "object",
                    "properties": [
                        "outcome": ["type": "string"],
                        "hyperparameters": ["type": "object", "description": "The learner."],
                        "closed": ["type": "object", "additionalProperties": false],
                    ],
                ],
                "configs": ["type": "array", "items": ["type": "object"]],
                "anything": true,
            ],
        ]
        let result = try SchemaConverter.convert(schema, name: "validate")
        XCTAssertEqual(
            result.openValues.sorted { $0.path.description < $1.path.description },
            [
                OpenValue(path: ValuePath([.key("anything")]), kind: .any),
                OpenValue(path: ValuePath([.key("config"), .key("hyperparameters")]), kind: .object),
                OpenValue(path: ValuePath([.key("configs"), .element]), kind: .object),
            ]
        )
        let json = try encoded(result.schema)
        let hp = try XCTUnwrap(json["properties"]?["config"]?["properties"]?["hyperparameters"])
        XCTAssertEqual(hp["type"]?.stringValue, "string")
        XCTAssertEqual(hp["description"]?.stringValue, "The learner. " + OpenValue.hint(for: .object, inArray: false))
        XCTAssertEqual(json["properties"]?["configs"]?["description"]?.stringValue, OpenValue.hint(for: .object, inArray: true))
        // A closed empty object stays an object: `{}` is all it admits.
        XCTAssertEqual(json["properties"]?["config"]?["properties"]?["closed"]?["type"]?.stringValue, "object")
        XCTAssertEqual(json["properties"]?["anything"]?["type"]?.stringValue, "string")
        XCTAssertEqual(json["properties"]?["anything"]?["description"]?.stringValue, OpenValue.hint(for: .any, inArray: false))
    }

    /// Open values inside a definition are recorded at every `$ref` site.
    func testOpenObjectsInsideDefinitions() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "first": ["$ref": "#/$defs/config"],
                "rest": ["type": "array", "items": ["$ref": "#/$defs/config"]],
            ],
            "$defs": [
                "config": ["type": "object", "properties": ["settings": ["type": "object"]]]
            ],
        ]
        let result = try SchemaConverter.convert(schema, name: "plan")
        XCTAssertEqual(
            result.openValues.map(\.path.description).sorted(),
            ["$.first.settings", "$.rest[].settings"]
        )
    }

    func testRestoreParsesJSONText() throws {
        let generated: JSONValue = [
            "config": ["outcome": "Death", "hyperparameters": "{\"algorithm\": \"glm\", \"lambda\": 0.5}"],
            "configs": ["{\"a\": 1}", "not json", "[1, 2]", ""],
            "anything": "42",
            "blank": " ",
            "quoted": "{'a': 'x y', 'n': 1}",
        ]
        let open = [
            OpenValue(path: ValuePath([.key("config"), .key("hyperparameters")]), kind: .object),
            OpenValue(path: ValuePath([.key("configs"), .element]), kind: .object),
            OpenValue(path: ValuePath([.key("anything")]), kind: .any),
            OpenValue(path: ValuePath([.key("missing")]), kind: .object),
            OpenValue(path: ValuePath([.key("blank")]), kind: .object),
            OpenValue(path: ValuePath([.key("quoted")]), kind: .object),
        ]
        let restored = OpenValue.restore(generated, open: open)
        XCTAssertEqual(restored["config"]?["hyperparameters"], ["algorithm": "glm", "lambda": 0.5])
        // Text that is not a JSON object stays as written for `.object`;
        // `.any` takes whatever parses; an empty string is removed.
        XCTAssertEqual(restored["configs"], [["a": 1], "not json", "[1, 2]"])
        XCTAssertEqual(restored["anything"], 42)
        XCTAssertNil(restored["missing"])
        XCTAssertNil(restored["blank"])
        // Single-quoted JSON text is read as JSON.
        XCTAssertEqual(restored["quoted"], ["a": "x y", "n": 1])
    }

    /// `"properties": {}` is a tool with no arguments, not an open object.
    func testNoParametersIsEmptyObject() throws {
        let result = try SchemaConverter.convert(["type": "object", "properties": [:]], name: "noop")
        let json = try encoded(result.schema)
        XCTAssertEqual(json["type"]?.stringValue, "object")
        XCTAssertEqual(json["properties"], [:])
        XCTAssertTrue(result.openValues.isEmpty)
    }

    /// rtemislive's real tool schemas (dumped from `boundedSchema` on the
    /// `devel` branch, September 2026). Regenerate the fixture when the
    /// published `supervised/v1` schema changes.
    func testRtemisliveFixtures() throws {
        let tools = try fixture("rtemis-tools")
        for (name, schema) in try XCTUnwrap(tools.objectValue) {
            let result = try SchemaConverter.convert(schema, name: name)
            let json = try encoded(result.schema)
            XCTAssertEqual(json["type"]?.stringValue, "object", name)
            if name == "validate_config" {
                let config = try XCTUnwrap(json["properties"]?["config"])
                XCTAssertNotNil(config["properties"]?["outcome"])
                XCTAssertNotNil(config["properties"]?["preprocessor_config"]?["properties"]?["impute"])
                // The six family placeholders are open objects: JSON text
                // the engine parses back. Without this the model could
                // never name an algorithm (`hyperparameters` would be `{}`).
                XCTAssertTrue(result.openValues.contains(OpenValue(path: ValuePath([.key("config"), .key("hyperparameters")]), kind: .object)))
                XCTAssertEqual(config["properties"]?["hyperparameters"]?["type"]?.stringValue, "string")
                // Every warning names a keyword the converter chose to skip;
                // none may be about a shape it failed to understand.
                for warning in result.warnings {
                    XCTAssertTrue(warning.contains("ignored"), warning)
                }
            }
        }
    }
}
