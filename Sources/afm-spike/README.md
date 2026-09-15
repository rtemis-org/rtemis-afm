# afm-spike — compatibility probe

`afm-spike` checks, against the real on-device model, the FoundationModels
behaviors that `rtemis-afm` is built on. It is the milestone-0 spike from the
implementation spec, kept as a program so it can be re-run.

```sh
swift run afm-spike
```

Needs an Apple silicon Mac with Apple Intelligence on. Exit status is `0` when
every check passes.

## When to run it

- After every macOS update (the model and the framework ship with the OS).
- After every Xcode update (the SDK interface can change; see below).
- Before a release.

## What it checks, and what the bridge does with the answer

| Check | Assumption | Where it matters |
|---|---|---|
| A | A `Transcript` built by the client from `.instructions` / `.prompt` / `.toolCalls` / `.toolOutput` entries is accepted, and `respond(to: "")` continues from a trailing tool result. | `TranscriptBuilder`; the stateless tool loop. If this fails, fall back to the per-conversation session registry described in the spec. |
| A2 | Prior `.response` entries are used as history. | Multi-turn chat. |
| B | Throwing from `Tool.call(arguments:)` surfaces the arguments the model produced, wrapped in `ToolCallError`. With `.preserveTranscript` (macOS 27) the session keeps the `.toolCalls` entry. | `BridgeTool`; `FoundationModelsBackend.toolCalls(from:)` reads all parallel calls from the transcript. |
| C, C2 | rtemislive's real tool schemas convert through `SchemaConverter` and the model fills them. | Tools in rtemislive. The fixture is `Tests/RtemisAFMTests/Fixtures/rtemis-tools.json`; regenerate it when the published `supervised/v1` schema changes. |
| D, D2 | `GenerationOptions.toolCallingMode` `.required` / `.disallowed` behave (macOS 27). | `tool_choice: "required"` and forced functions. |
| E | Text snapshots are cumulative. | Delta computation in the backend. |
| E2 | Structured snapshots are partial JSON, not prefixes. | Why `response_format: json_schema` streams the final object once. |
| F | `Response.usage` reports token counts (macOS 27). | `usage` on the wire; macOS 26 gets a character-based estimate. |
| F2 | An oversized prompt throws a context-size error, which `ErrorMapper` turns into `400 context_length_exceeded`. | Honest status codes. |
| G | Task cancellation stops generation quickly. | Cancel-on-disconnect. |

## Findings on record

**macOS 27.0 (25A428), Xcode 27.0, Swift 6.4 — 2026-09-15:** all checks
pass. `contextSize` reports 8192; the model variant is "AFM 3 Core Advanced";
`capabilities` include vision, tool calling and guided generation (no
reasoning). `GenerationSchema` is `Codable` but only in its own dialect (it
requires `title` and `x-order` and rejects `type: [..]`), so JSON Schema
must go through `DynamicGenerationSchema`. A prompt made of one phrase
repeated thousands of times trips the *guardrails* before the context
check; varied text produces the context-size error.

## Reading the SDK interface

The authoritative list of what the framework offers on a given Xcode is its
module interface. To diff it against what the code assumes:

```sh
SDK=$(xcrun --sdk macosx --show-sdk-path)
less "$SDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
```

Look for: `LanguageModelSession.GenerationError` and `LanguageModelError`
cases (→ `ErrorMapper`), `DynamicGenerationSchema` initializers
(→ `SchemaConverter`), `Transcript.Entry` cases (→ `TranscriptBuilder`),
`GenerationOptions` fields (→ `RequestPreparer`), and the `@available`
annotations that decide which `#available` guards can be dropped.
