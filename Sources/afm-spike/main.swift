import Foundation
import FoundationModels

// Quick M0 probe — replaced by the documented version once findings are in.

let model = SystemLanguageModel.default
print("availability:", model.availability)
print("contextSize:", model.contextSize)
if #available(macOS 27, *) {
    print("variant:", model.variant.displayName, "caps: vision=\(model.capabilities.contains(.vision)) tools=\(model.capabilities.contains(.toolCalling)) guided=\(model.capabilities.contains(.guidedGeneration)) reasoning=\(model.capabilities.contains(.reasoning))")
}

struct Intercepted: Error { let name: String; let json: String }

struct BridgeTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    func call(arguments: GeneratedContent) async throws -> String {
        print("  [tool \(name) called with]", arguments.jsonString)
        throw Intercepted(name: name, json: arguments.jsonString)
    }
}

func schema(_ json: String) throws -> GenerationSchema {
    // Minimal hand-built dynamic schema for the probe; the real converter lives in the library.
    if json.contains("colors") {
        let arr = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 3, maximumElements: 3)
        let root = DynamicGenerationSchema(name: "Colors", properties: [.init(name: "colors", schema: arr)])
        return try GenerationSchema(root: root, dependencies: [])
    }
    let root = DynamicGenerationSchema(name: "get_weather", description: nil, properties: [
        .init(name: "city", description: "City name", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "unit", schema: DynamicGenerationSchema(name: "unit", anyOf: ["c", "f"]), isOptional: true),
    ])
    return try GenerationSchema(root: root, dependencies: [])
}

// (c1) Does GenerationSchema decode from JSON Schema?
print("\n== (c1) GenerationSchema from JSON Schema")
let weatherJSON = """
{"type":"object","properties":{"city":{"type":"string","description":"City name"},"unit":{"type":"string","enum":["c","f"]}},"required":["city"]}
"""
let weatherSchema: GenerationSchema
do {
    weatherSchema = try schema(weatherJSON)
    print("decoded OK:", weatherSchema.debugDescription.prefix(300))
    let enc = try JSONEncoder().encode(weatherSchema)
    print("re-encoded:", String(decoding: enc, as: UTF8.self).prefix(400))
} catch {
    print("decode FAILED:", error); exit(1)
}

// Real rtemislive fixture
let fixtureURL = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-sdg-Code-rtemis-afm/d7e815b5-59aa-4574-9fcc-d75b6466e1af/scratchpad/rtemis-tools.json")
if let data = try? Data(contentsOf: fixtureURL),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    for (name, sch) in obj {
        let d = try JSONSerialization.data(withJSONObject: sch)
        do {
            var obj2 = try JSONSerialization.jsonObject(with: d) as! [String: Any]
            func addOrder(_ o: inout [String: Any]) {
                if let props = o["properties"] as? [String: Any] {
                    var np: [String: Any] = [:]
                    for (k, v) in props { var vv = v as! [String: Any]; addOrder(&vv); np[k] = vv }
                    o["properties"] = np; o["x-order"] = Array(props.keys).sorted()
                }
                if var items = o["items"] as? [String: Any] { addOrder(&items); o["items"] = items }
            }
            addOrder(&obj2)
            let d2 = try JSONSerialization.data(withJSONObject: obj2)
            let s = try JSONDecoder().decode(GenerationSchema.self, from: d2)
            if #available(macOS 26.4, *) { print("fixture \(name): decoded OK; tokenCount:", (try? await model.tokenCount(for: s)) ?? -1) }
        } catch { print("fixture \(name): FAILED", error) }
    }
}

// (b) throw from call
print("\n== (b) throw from call")
let tool = BridgeTool(name: "get_weather", description: "Get the current weather for a city.", parameters: weatherSchema)
let session = LanguageModelSession(model: model, tools: [tool], instructions: "You are a helpful assistant. Use tools when relevant.")
if #available(macOS 27, *) { session.transcriptErrorHandlingPolicy = .preserveTranscript }
do {
    let r = try await session.respond(to: "What's the weather in Paris right now?")
    print("no tool call; answered:", r.content)
} catch let e as LanguageModelSession.ToolCallError {
    print("ToolCallError tool=\(e.tool.name) underlying=\(e.underlyingError)")
    print("transcript after error:")
    for entry in session.transcript { print("  ", entry) }
} catch {
    print("other error:", error)
}

// (a) transcript with tool entries, then continuation
print("\n== (a) transcript with toolCalls/toolOutput")
let args = try GeneratedContent(json: #"{"city":"Paris","unit":"c"}"#)
var entries: [Transcript.Entry] = [
    .instructions(.init(segments: [.text(.init(content: "You are a helpful assistant."))], toolDefinitions: [.init(tool: tool)])),
    .prompt(.init(segments: [.text(.init(content: "What's the weather in Paris right now?"))])),
    .toolCalls(.init([.init(id: "call_1", toolName: "get_weather", arguments: args)])),
    .toolOutput(.init(id: "call_1", toolName: "get_weather", segments: [.text(.init(content: #"{"temperature_c": 18, "sky": "overcast"}"#))])),
]
let s2 = LanguageModelSession(model: model, tools: [tool], transcript: Transcript(entries: entries))
for variant in ["empty prompt", "prompt builder"] {
    do {
        let r: LanguageModelSession.Response<String>
        if variant == "empty prompt" { r = try await s2.respond(to: "") }
        else { r = try await s2.respond { "" } }
        print("[\(variant)] continued OK:", r.content)
        if #available(macOS 27, *) { print("  usage in=\(r.usage.input.totalTokenCount) out=\(r.usage.output.totalTokenCount)") }
        break
    } catch { print("[\(variant)] FAILED:", error) }
}

// (a2) multi-turn with prior response entries
print("\n== (a2) prior assistant response entry")
entries = [
    .instructions(.init(segments: [.text(.init(content: "Answer briefly."))], toolDefinitions: [])),
    .prompt(.init(segments: [.text(.init(content: "My name is Ada."))])),
    .response(.init(assetIDs: [], segments: [.text(.init(content: "Nice to meet you, Ada!"))])),
]
let s3 = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
let r3 = try await s3.respond(to: "What is my name?")
print("answer:", r3.content)

// (d) tool_choice required
if #available(macOS 27, *) {
    print("\n== (d) toolCallingMode .required")
    let s4 = LanguageModelSession(model: model, tools: [tool], instructions: "You are a helpful assistant.")
    do {
        let r = try await s4.respond(to: "Say hello.", options: .init(samplingMode: nil, temperature: nil, maximumResponseTokens: nil, toolCallingMode: .required))
        print("no tool call:", r.content)
    } catch let e as LanguageModelSession.ToolCallError { print("required → tool called:", e.tool.name, e.underlyingError) }
    catch { print("required error:", error) }
    print("\n== (d2) toolCallingMode .disallowed")
    do {
        let r = try await s4.respond(to: "What's the weather in Paris?", options: .init(samplingMode: nil, temperature: nil, maximumResponseTokens: nil, toolCallingMode: .disallowed))
        print("disallowed → text:", r.content.prefix(120))
    } catch { print("disallowed error:", error) }
}

// (e) streaming snapshots: text and structured
print("\n== (e) streaming")
let s5 = LanguageModelSession(model: model, instructions: "Answer briefly.")
var last = ""
var n = 0
for try await snap in s5.streamResponse(to: "Name three colors, one per line.") {
    n += 1
    if !snap.content.hasPrefix(last) { print("  NOT cumulative! prev=\(last) now=\(snap.content)") }
    last = snap.content
}
print("snapshots:", n, "final:", last.replacingOccurrences(of: "\n", with: "\\n"))
let s6 = LanguageModelSession(model: model, instructions: "Answer briefly.")
let outSchema = try schema(#"{"type":"object","properties":{"colors":{"type":"array","items":{"type":"string"},"minItems":3,"maxItems":3}},"required":["colors"]}"#)
n = 0; var lastJSON = ""
for try await snap in s6.streamResponse(to: "Name three colors.", schema: outSchema) {
    n += 1; lastJSON = snap.rawContent.jsonString
    if n <= 3 { print("  partial:", lastJSON) }
}
print("structured snapshots:", n, "final:", lastJSON)

// (f) errors: context overflow
print("\n== (f) context overflow")
let s7 = LanguageModelSession(model: model)
let big = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 1500)
do { _ = try await s7.respond(to: big); print("no error?!") }
catch let e as LanguageModelSession.GenerationError { print("GenerationError:", e) }
catch { if #available(macOS 27, *), let e = error as? LanguageModelError { print("LanguageModelError:", e) } else { print("other:", type(of: error), error) } }

// (g) cancellation
print("\n== (g) cancellation")
let t = Task { () -> String in
    let s = LanguageModelSession(model: model)
    let r = try await s.respond(to: "Write a 500 word essay about rivers.")
    return r.content
}
try await Task.sleep(for: .milliseconds(300))
t.cancel()
let start = Date()
switch await t.result {
case .success(let s): print("completed anyway after \(Date().timeIntervalSince(start))s, \(s.count) chars")
case .failure(let e): print("cancelled after \(Date().timeIntervalSince(start))s:", type(of: e), e)
}
print("\nDone.")
