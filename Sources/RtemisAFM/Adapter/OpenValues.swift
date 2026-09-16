// OpenValues.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation

/// A place in a generated value: the keys and array steps from the root.
///
/// `SchemaConverter` records one for every schema node it had to encode as
/// JSON text (see `OpenValue`), and `OpenValue.restore` walks generated
/// output along it. Array steps match every element, so one path covers
/// `configs[0].hyperparameters`, `configs[1].hyperparameters`, and so on.
public struct ValuePath: Equatable, Sendable, CustomStringConvertible {
    public enum Step: Equatable, Sendable {
        case key(String)
        case element
    }

    public var steps: [Step]

    public init(_ steps: [Step] = []) {
        self.steps = steps
    }

    public var isRoot: Bool { steps.isEmpty }

    public func appending(_ step: Step) -> ValuePath {
        ValuePath(steps + [step])
    }

    public func appending(_ other: ValuePath) -> ValuePath {
        ValuePath(steps + other.steps)
    }

    /// `$.configs[].hyperparameters` — for logs and tests.
    public var description: String {
        "$" + steps.map { step -> String in
            switch step {
            case .key(let key): return "." + key
            case .element: return "[]"
            }
        }.joined()
    }
}

/// A schema node the model cannot write as structured output, because
/// guided generation has no way to say "any object", and the encoding the
/// bridge asks for instead (spec: rtemis-afm/wire#open-objects).
///
/// `DynamicGenerationSchema` describes objects by their properties. A JSON
/// Schema `{"type": "object"}` with no `properties` keyword at all — an
/// "open" object, which clients use for free-form settings — converts to
/// an object with no properties, and the only value the model can then
/// produce is `{}`. (An explicit `"properties": {}` is different: by
/// OpenAI convention it is a tool that takes no arguments, and `{}` is
/// exactly right for it.) The framework's own free-form type
/// (`GeneratedContent.generationSchema`, "Any legal JSON") does not help:
/// on macOS 27.0 the model either emits `{}` for it or the constrained
/// decoder doubles the key quotes and the generation fails.
///
/// So the converter encodes an open object as JSON *text* in a string,
/// records its path here, and the engine parses the text back into JSON
/// before it reaches the wire. The client never sees the detour. Asked
/// this way the model writes valid JSON reliably in a short context
/// (spike check H, 3/3), less so after it has read pages of compact JSON
/// tool results, where it sometimes ends the string early on an unescaped
/// quote. Text that is not JSON is left as it was written and the client's
/// own validation reports it; an empty string for an optional value is
/// removed, since "nothing" is what it means. Single-quoted JSON
/// (`{'a': 1}`) is accepted too.
///
/// A client that needs a free-form block to be reliable on a small model
/// does better to declare the fields that matter (rtemislive's compact
/// profile does: `boundedSchema.ts`) and keep the open part small.
///
/// **Future updates:** re-run spike check H after each macOS/Xcode update.
/// If `GeneratedContent.generationSchema` starts generating correctly, the
/// converter can map open objects to it and this file becomes unnecessary.
/// The check also tries a list of `key: value` strings as an alternative
/// encoding; on macOS 27.0 it was no better in context.
public struct OpenValue: Equatable, Sendable {
    /// What the JSON text must parse to before it replaces the string.
    public enum Kind: Equatable, Sendable {
        /// The schema said `object`, or the response format is
        /// `json_object`: only a parsed object is accepted.
        case object
        /// The schema said nothing (`true` or `{}`): any JSON is accepted.
        case any
    }

    public var path: ValuePath
    public var kind: Kind

    public init(path: ValuePath, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    /// The sentence appended to a property's description so the model
    /// knows to write JSON text. `inArray` phrases it per item when the
    /// open value sits inside the property's array.
    ///
    /// Deliberately without an example: given `{"name": "value"}` the model
    /// copies the key `name` into its output instead of the key the
    /// description asked for (spike check H tried it).
    public static func hint(for kind: Kind, inArray: Bool) -> String {
        let what = inArray ? "each item" : "it"
        switch kind {
        case .object:
            return "Write \(what) as JSON text: an object in a string."
        case .any:
            return "Write \(what) as JSON text in a string."
        }
    }

    /// JSON from text the model wrote: strict JSON first, then the
    /// single-quoted form (`{'algorithm': 'glm'}`) a model sometimes
    /// prefers inside a string.
    static func parseJSONText(_ text: String) -> JSONValue? {
        if let strict = try? JSONValue(parsing: text) { return strict }
        guard text.contains("'") else { return nil }
        return try? JSONValue(parsing: text.replacingOccurrences(of: "'", with: "\""))
    }

    /// `value` with every open value at `open` parsed from JSON text.
    public static func restore(_ value: JSONValue, open: [OpenValue]) -> JSONValue {
        open.reduce(value) { current, item in
            restore(current, steps: item.path.steps[...], kind: item.kind) ?? current
        }
    }

    /// `nil` means "remove this value": the model wrote an empty string
    /// where an open value was expected.
    private static func restore(_ value: JSONValue, steps: ArraySlice<ValuePath.Step>, kind: Kind) -> JSONValue? {
        guard let step = steps.first else {
            if let text = value.stringValue, text.allSatisfy(\.isWhitespace) { return nil }
            return parsed(value, kind: kind) ?? value
        }
        let rest = steps.dropFirst()
        switch (step, value) {
        case (.key(let key), .object(var object)):
            if let child = object[key] {
                object[key] = restore(child, steps: rest, kind: kind)
            }
            return .object(object)
        case (.element, .array(let elements)):
            return .array(elements.compactMap { restore($0, steps: rest, kind: kind) })
        default:
            // The model produced a different shape than the schema said;
            // nothing to restore here.
            return value
        }
    }

    private static func parsed(_ value: JSONValue, kind: Kind) -> JSONValue? {
        guard let text = value.stringValue, let json = parseJSONText(text) else { return nil }
        // Written out rather than as `cond ? json : nil`: `JSONValue` is
        // `ExpressibleByNilLiteral`, so that `nil` would be `.null`.
        switch kind {
        case .object:
            if json.objectValue == nil { return nil }
            return json
        case .any:
            return json
        }
    }
}
