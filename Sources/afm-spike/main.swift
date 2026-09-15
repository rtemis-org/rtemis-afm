// main.swift — afm-spike
// ::rtemis-afm::
// 2026- EDG rtemis.org
//
// A compatibility probe for the FoundationModels behaviors rtemis-afm
// depends on. It is not a test suite: it talks to the real on-device model,
// so it needs a Mac with Apple Intelligence turned on, and it *prints* what
// it finds rather than asserting. Run it after every macOS or Xcode update:
//
//     swift run afm-spike
//
// Each numbered check corresponds to an assumption documented in
// `Sources/afm-spike/README.md`. A check that reports FAIL means the bridge
// needs a code change before it can be trusted on that OS version.

import Foundation
import FoundationModels
import RtemisAFM

// MARK: - Helpers

// Top-level code in `main.swift` runs on the main actor; the helper is
// marked so too, which lets it mutate the counter.
var failures = 0

@MainActor
func check(_ id: String, _ title: String, _ body: () async throws -> String) async {
    print("\n[\(id)] \(title)")
    do {
        let detail = try await body()
        print("  PASS — \(detail)")
    } catch {
        failures += 1
        print("  FAIL — \(error)")
    }
}

struct SpikeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Builds a `GenerationSchema` from JSON Schema through the bridge's own
/// converter, so the probe exercises the same code the server runs.
func schema(_ json: JSONValue, name: String) throws -> GenerationSchema {
    try SchemaConverter.convert(json, name: name).schema
}

let weatherSchema: JSONValue = [
    "type": "object",
    "properties": [
        "city": ["type": "string", "description": "City name"],
        "unit": ["type": "string", "enum": ["celsius", "fahrenheit"]],
    ],
    "required": ["city"],
]

// MARK: - Environment

let model = SystemLanguageModel.default
let os = ProcessInfo.processInfo.operatingSystemVersionString
print("afm-spike for rtemis-afm \(RtemisAFM.version) — macOS \(os)")
print("availability: \(model.availability)")
print("contextSize: \(model.contextSize)")
let caps = model.capabilities
print("variant: \(model.variant.displayName); capabilities: vision=\(caps.contains(.vision)) tools=\(caps.contains(.toolCalling)) guided=\(caps.contains(.guidedGeneration)) reasoning=\(caps.contains(.reasoning))")
guard model.isAvailable else {
    print("The model is unavailable; nothing else can be checked.")
    exit(2)
}

let weatherTool = BridgeTool(name: "get_weather", description: "Get the current weather for a city.", parameters: try schema(weatherSchema, name: "get_weather"))

// MARK: - A. Client-authored transcript with tool entries

await check("A", "Transcript with .toolCalls/.toolOutput continues from a tool result") {
    let args = try GeneratedContent(json: #"{"city":"Paris","unit":"celsius"}"#)
    let entries: [Transcript.Entry] = [
        .instructions(.init(segments: [.text(.init(content: "You are a helpful assistant."))], toolDefinitions: [.init(tool: weatherTool)])),
        .prompt(.init(segments: [.text(.init(content: "What's the weather in Paris right now?"))])),
        .toolCalls(.init([.init(id: "call_1", toolName: "get_weather", arguments: args)])),
        .toolOutput(.init(id: "call_1", toolName: "get_weather", segments: [.text(.init(content: #"{"temperature_c": 18, "sky": "overcast"}"#))])),
    ]
    let session = LanguageModelSession(model: model, tools: [weatherTool], transcript: Transcript(entries: entries))
    // The bridge passes an empty prompt when the history ends with a tool result.
    let response = try await session.respond(to: "")
    guard response.content.contains("18") else {
        throw SpikeFailure("the answer did not use the tool output: \(response.content)")
    }
    return "answer used the tool output: \"\(response.content.prefix(80))\""
}

await check("A2", "Transcript with a prior .response entry is remembered") {
    let entries: [Transcript.Entry] = [
        .instructions(.init(segments: [.text(.init(content: "Answer briefly."))], toolDefinitions: [])),
        .prompt(.init(segments: [.text(.init(content: "My name is Ada."))])),
        .response(.init(assetIDs: [], segments: [.text(.init(content: "Nice to meet you, Ada!"))])),
    ]
    let session = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
    let response = try await session.respond(to: "What is my name?")
    guard response.content.contains("Ada") else { throw SpikeFailure("got \(response.content)") }
    return "\"\(response.content.prefix(60))\""
}

// MARK: - B. Throwing from Tool.call

await check("B", "Throwing from Tool.call surfaces the model's arguments; transcript keeps the .toolCalls entry") {
    let session = LanguageModelSession(model: model, tools: [weatherTool], instructions: "You are a helpful assistant. Use tools when relevant.")
    session.transcriptErrorHandlingPolicy = .preserveTranscript
    do {
        let response = try await session.respond(to: "What's the weather in Paris right now?")
        throw SpikeFailure("the model answered without calling the tool: \(response.content)")
    } catch let error as LanguageModelSession.ToolCallError {
        guard let intercepted = error.underlyingError as? ToolCallIntercepted else {
            throw SpikeFailure("unexpected underlying error \(error.underlyingError)")
        }
        let city = try intercepted.arguments.value(String.self, forProperty: "city")
        let kept = session.transcript.contains { if case .toolCalls = $0 { return true } else { return false } }
        guard kept else { throw SpikeFailure("preserveTranscript did not keep the .toolCalls entry") }
        return "intercepted \(intercepted.toolName)(city: \(city)); .toolCalls entry preserved (\(session.transcript.count) entries)"
    }
}

// MARK: - C. JSON Schema shapes

await check("C", "rtemislive's real tool schemas convert and are accepted by the model") {
    // The fixture lives with the unit tests; resolve it relative to this file.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appending(path: "Tests/RtemisAFMTests/Fixtures/rtemis-tools.json")
    let tools = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
    var summary: [String] = []
    for (name, json) in tools.objectValue ?? [:] {
        let result = try SchemaConverter.convert(json, name: name)
        summary.append("\(name): ok, \(result.warnings.count) warnings, \(try await model.tokenCount(for: result.schema)) tokens")
    }
    return summary.joined(separator: "; ")
}

await check("C2", "The model fills rtemislive's validate_config tool from a plain request") {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appending(path: "Tests/RtemisAFMTests/Fixtures/rtemis-tools.json")
    let tools = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
    let validate = BridgeTool(
        name: "rtemis_validate_config",
        description: "Check an rtemis config against the schema and the loaded dataset. Returns findings.",
        parameters: try schema(tools["validate_config"]!, name: "rtemis_validate_config")
    )
    let session = LanguageModelSession(model: model, tools: [validate], instructions: "You plan machine-learning runs with rtemis. Use tools.")
    do {
        let response = try await session.respond(to: "Validate a config with algorithm glmnet, outcome column 'diagnosis', features 'age' and 'bmi'.")
        throw SpikeFailure("no tool call; the model said: \(response.content.prefix(120))")
    } catch let error as LanguageModelSession.ToolCallError {
        let intercepted = error.underlyingError as! ToolCallIntercepted
        return "arguments: \(intercepted.arguments.jsonString.prefix(160))"
    }
}

// MARK: - D. Tool calling modes

do {
    await check("D", "toolCallingMode .required forces a call") {
        let session = LanguageModelSession(model: model, tools: [weatherTool], instructions: "You are a helpful assistant.")
        let options = GenerationOptions(samplingMode: nil, temperature: nil, maximumResponseTokens: nil, toolCallingMode: .required)
        do {
            let response = try await session.respond(to: "Say hello.", options: options)
            throw SpikeFailure("no tool call: \(response.content)")
        } catch let error as LanguageModelSession.ToolCallError {
            return "called \(error.tool.name)"
        }
    }
    await check("D2", "toolCallingMode .disallowed suppresses calls") {
        let session = LanguageModelSession(model: model, tools: [weatherTool], instructions: "You are a helpful assistant.")
        let options = GenerationOptions(samplingMode: nil, temperature: nil, maximumResponseTokens: nil, toolCallingMode: .disallowed)
        let response = try await session.respond(to: "What's the weather in Paris?", options: options)
        return "text answer: \"\(response.content.prefix(60))\""
    }
}

// MARK: - E. Streaming

await check("E", "Text snapshots are cumulative (each extends the previous)") {
    let session = LanguageModelSession(model: model, instructions: "Answer briefly.")
    var previous = ""
    var count = 0
    for try await snapshot in session.streamResponse(to: "Name three colors, one per line.") {
        count += 1
        guard snapshot.content.hasPrefix(previous) else {
            throw SpikeFailure("snapshot \(count) is not an extension of the previous one")
        }
        previous = snapshot.content
    }
    return "\(count) snapshots, final \(previous.count) chars"
}

await check("E2", "Structured snapshots are partial JSON, not text prefixes (so the bridge sends the final object once)") {
    let session = LanguageModelSession(model: model, instructions: "Answer briefly.")
    let colors = try schema(["type": "object", "properties": ["colors": ["type": "array", "items": ["type": "string"], "minItems": 3, "maxItems": 3]], "required": ["colors"]], name: "colors")
    var last = ""
    var count = 0
    for try await snapshot in session.streamResponse(to: "Name three colors.", schema: colors) {
        count += 1
        last = snapshot.rawContent.jsonString
    }
    let parsed = try JSONValue(parsing: last)
    guard parsed["colors"]?.arrayValue?.count == 3 else { throw SpikeFailure("final JSON: \(last)") }
    return "\(count) snapshots, final \(last)"
}

// MARK: - F. Token accounting and errors

await check("F", "Response.usage reports token counts") {
    let session = LanguageModelSession(model: model)
    let response = try await session.respond(to: "Say OK.")
    guard response.usage.input.totalTokenCount > 0, response.usage.output.totalTokenCount > 0 else {
        throw SpikeFailure("usage is zero")
    }
    return "in=\(response.usage.input.totalTokenCount) out=\(response.usage.output.totalTokenCount)"
}

await check("F2", "An oversized prompt is reported as a context-size error (mapped to 400)") {
    // Varied text: a *repeated* phrase trips the guardrails first (a known
    // quirk — see the README).
    var words: [String] = []
    var seed: UInt64 = 42
    for _ in 0..<9000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        words.append("w\(seed % 100_000)")
    }
    let session = LanguageModelSession(model: model)
    do {
        _ = try await session.respond(to: "Summarize: " + words.joined(separator: " "))
        throw SpikeFailure("no error for a ~9k-word prompt")
    } catch {
        let mapped = ErrorMapper.map(error)
        guard mapped.code == "context_length_exceeded" else { throw SpikeFailure("mapped to \(mapped.status) \(mapped.code ?? "-"): \(mapped.message)") }
        return "\(type(of: error)) → \(mapped.status) \(mapped.code!)"
    }
}

// MARK: - G. Cancellation

await check("G", "Cancelling the task stops generation promptly") {
    let task = Task {
        let session = LanguageModelSession(model: model)
        return try await session.respond(to: "Write a 500 word essay about rivers.").content
    }
    try await Task.sleep(for: .milliseconds(300))
    let start = ContinuousClock.now
    task.cancel()
    switch await task.result {
    case .success: throw SpikeFailure("completed anyway")
    case .failure(let error):
        let elapsed = ContinuousClock.now - start
        guard elapsed < .seconds(2) else { throw SpikeFailure("took \(elapsed) to stop") }
        return "\(type(of: error)) after \(elapsed)"
    }
}

// MARK: - Summary

print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")")
exit(failures == 0 ? 0 : 1)
