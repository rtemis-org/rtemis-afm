// RequestPreparer.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels

/// A chat request after validation and conversion: everything the engine
/// needs to open a `LanguageModelSession` and generate.
public struct PreparedChat: Sendable {
    public var transcript: Transcript
    public var prompt: String
    /// Images attached to the prompt, in wire order.
    public var promptImages: [Transcript.ImageAttachment]
    public var tools: [BridgeTool]
    public var options: GenerationOptions
    /// Set for `response_format: json_schema` and `json_object`; the model
    /// is constrained to it.
    public var responseSchema: GenerationSchema?
    /// Where in the structured response the model writes JSON text that
    /// must be parsed back (see `OpenValue`). For `json_object` this is the
    /// root: the whole response is one JSON string to unwrap.
    public var responseOpenValues: [OpenValue] = []
    /// Schema-conversion warnings, for the verbose log.
    public var warnings: [String]
    /// Text of the instructions, for logging and diagnostics.
    public var instructionsText: String

    /// Whether the model is asked to look at an image anywhere — on the
    /// prompt or earlier in the conversation.
    public var hasImages: Bool {
        !promptImages.isEmpty || transcript.contains { entry in
            if case .prompt(let prompt) = entry {
                return prompt.segments.contains { if case .attachment = $0 { true } else { false } }
            }
            return false
        }
    }
}

/// Validates a wire request and converts it into a `PreparedChat`.
///
/// This is pure: no model, no I/O, so it is unit-tested directly. Every
/// failure is a `BridgeError` with the right HTTP status.
public enum RequestPreparer {
    public static func prepare(_ request: ChatCompletionRequest) throws(BridgeError) -> PreparedChat {
        guard RtemisAFM.acceptedModelIDs.contains(request.model) else {
            throw .modelNotFound(request.model)
        }

        var warnings: [String] = []

        // --- Tools -------------------------------------------------------
        var tools: [BridgeTool] = []
        var toolCallingMode: ToolCallingMode = .auto
        let toolChoice = request.toolChoice ?? .auto
        let definitions = request.tools ?? []

        switch toolChoice {
        case .none:
            // The tools are simply not offered to the model.
            toolCallingMode = .auto
        case .auto:
            tools = try convertTools(definitions, warnings: &warnings)
        case .required:
            guard !definitions.isEmpty else { throw .invalidRequest("tool_choice \"required\" but no tools were given") }
            tools = try convertTools(definitions, warnings: &warnings)
            toolCallingMode = .required
        case .function(let name):
            // OpenAI's forced call = "call exactly this function". The
            // framework cannot name a tool, but offering only that tool and
            // requiring a call amounts to the same thing.
            let chosen = definitions.filter { $0.function.name == name }
            guard !chosen.isEmpty else {
                throw .invalidRequest("tool_choice names \"\(name)\" but no such tool was given", code: "invalid_tool_choice")
            }
            tools = try convertTools(chosen, warnings: &warnings)
            toolCallingMode = .required
        }

        // --- Response format ---------------------------------------------
        var responseSchema: GenerationSchema?
        var responseOpenValues: [OpenValue] = []
        var extraInstructions: String?
        if let format = request.responseFormat {
            switch format.type {
            case "text", "":
                break
            case "json_object":
                // No schema to constrain to, and an object schema with no
                // properties would only ever produce `{}`. The response is
                // instead generated as one string that the engine parses
                // (the same detour open objects take; see `OpenValue`), with
                // the instructions saying what to put in it.
                extraInstructions = "Respond with a single JSON object and nothing else."
                do {
                    responseSchema = try GenerationSchema(root: DynamicGenerationSchema(type: String.self), dependencies: [])
                } catch {
                    throw ErrorMapper.map(error)
                }
                responseOpenValues = [OpenValue(path: ValuePath(), kind: .object)]
            case "json_schema":
                guard let spec = format.jsonSchema, let schema = spec.schema else {
                    throw .invalidRequest("response_format.json_schema.schema is required", code: "invalid_response_format")
                }
                do {
                    let converted = try SchemaConverter.convert(schema, name: spec.name ?? "response")
                    responseSchema = converted.schema
                    responseOpenValues = converted.openValues
                    warnings += converted.warnings.map { "response_format: \($0)" }
                } catch let error as SchemaConverter.SchemaConversionError {
                    throw .invalidRequest("unsupported schema in response_format: \(error)", code: "unsupported_schema")
                } catch {
                    throw ErrorMapper.map(error)
                }
            default:
                throw .unsupported("response_format type \"\(format.type)\" is not supported")
            }
        }

        // --- Messages → Transcript ----------------------------------------
        let toolDefinitions = tools.map { Transcript.ToolDefinition(tool: $0) }
        let built = try TranscriptBuilder.build(
            messages: request.messages,
            toolDefinitions: toolDefinitions,
            extraInstructions: extraInstructions
        )

        // --- Sampling options ----------------------------------------------
        let options = generationOptions(for: request, toolCallingMode: toolCallingMode)

        return PreparedChat(
            transcript: built.transcript,
            prompt: built.prompt,
            promptImages: built.promptImages,
            tools: tools,
            options: options,
            responseSchema: responseSchema,
            responseOpenValues: responseOpenValues,
            warnings: warnings,
            instructionsText: built.instructionsText
        )
    }

    /// Which `GenerationOptions.ToolCallingMode` to set: `.auto` leaves the
    /// framework's default (`nil`), `.required` forces a call.
    enum ToolCallingMode { case auto, required }

    static func convertTools(_ definitions: [ToolDefinition], warnings: inout [String]) throws(BridgeError) -> [BridgeTool] {
        var tools: [BridgeTool] = []
        var seen: Set<String> = []
        for definition in definitions {
            let function = definition.function
            guard !function.name.isEmpty else { throw .invalidRequest("tools[].function.name must not be empty", code: "invalid_tools") }
            guard seen.insert(function.name).inserted else {
                throw .invalidRequest("duplicate tool name \"\(function.name)\"", code: "invalid_tools")
            }
            // A tool without parameters takes an empty object.
            let parameters = function.parameters ?? ["type": "object", "properties": [:]]
            do {
                let converted = try SchemaConverter.convert(parameters, name: function.name)
                warnings += converted.warnings.map { "tool \(function.name): \($0)" }
                tools.append(BridgeTool(
                    name: function.name,
                    description: function.description ?? "",
                    parameters: converted.schema,
                    openValues: converted.openValues
                ))
            } catch let error as SchemaConverter.SchemaConversionError {
                throw .invalidRequest("unsupported schema for tool \"\(function.name)\": \(error)", code: "unsupported_schema")
            } catch {
                throw ErrorMapper.map(error)
            }
        }
        return tools
    }

    /// Maps the wire's sampling knobs onto `GenerationOptions`.
    ///
    /// `top_p` → `.random(probabilityThreshold:)`, `top_k` → `.random(top:)`
    /// (`top_p` wins if both are set); `seed` rides along with either.
    /// Temperature and the token cap map one to one.
    static func generationOptions(for request: ChatCompletionRequest, toolCallingMode: ToolCallingMode) -> GenerationOptions {
        var sampling: GenerationOptions.SamplingMode?
        if let topP = request.topP {
            sampling = .random(probabilityThreshold: topP, seed: request.seed)
        } else if let topK = request.topK {
            sampling = .random(top: topK, seed: request.seed)
        }
        var options = GenerationOptions(
            samplingMode: sampling,
            temperature: request.temperature,
            maximumResponseTokens: request.effectiveMaxTokens
        )
        switch toolCallingMode {
        case .auto: options.toolCallingMode = nil
        case .required: options.toolCallingMode = .required
        }
        return options
    }
}
