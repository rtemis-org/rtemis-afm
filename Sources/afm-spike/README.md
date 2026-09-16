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
| B | Throwing from `Tool.call(arguments:)` surfaces the arguments the model produced, wrapped in `ToolCallError`. With `.preserveTranscript` the session keeps the `.toolCalls` entry. | `BridgeTool`; `FoundationModelsBackend.toolCalls(from:)` reads all parallel calls from the transcript. |
| C, C2 | rtemislive's real tool schemas convert through `SchemaConverter` and the model fills them. | Tools in rtemislive. The fixture is `Tests/RtemisAFMTests/Fixtures/rtemis-tools.json`; regenerate it when the published `supervised/v1` schema changes. |
| D, D2 | `GenerationOptions.toolCallingMode` `.required` / `.disallowed` behave. | `tool_choice: "required"` and forced functions. |
| E | Text snapshots are cumulative. | Delta computation in the backend. |
| E2 | Structured snapshots are partial JSON, not prefixes. | Why `response_format: json_schema` streams the final object once. |
| F | `Response.usage` reports token counts. | `usage` on the wire. |
| F2 | An oversized prompt throws `LanguageModelError.contextSizeExceeded`, which `ErrorMapper` turns into `400 context_length_exceeded`. The printed type matters: built for macOS 27 the framework throws `LanguageModelError`; built for 26 it threw the deprecated `GenerationError`. | Honest status codes; `ErrorMapper` handles only the new enum. |
| F3 | The same overflow with a tool attached arrives as `GenerativeError`, a type the public interface does not declare, with the message "Provided N tokens, but the maximum allowed is M." | `ErrorMapper` matches that message so the client gets `400 context_length_exceeded` either way. If this check prints `LanguageModelError`, the framework was fixed and the message match can go. |
| G | Task cancellation stops generation quickly. | Cancel-on-disconnect. |
| H | An open object (`{"type": "object"}` with no `properties`) cannot be generated as structured output: with the framework's free-form `GeneratedContent.generationSchema` the macOS 27.0 model emits `{}` or the constrained decoder doubles the key quotes and fails. Asked for the object as JSON *text* in a string, it writes valid JSON every time. | `OpenValue` / `SchemaConverter`: open objects go on the wire as strings with a hint and are parsed back in the engine. If this check reports that free-form works too, the detour can go. |

## Findings on record

**macOS 27.0 (25A428), Xcode 27.0, Swift 6.4 — 2026-09-15:** all checks
pass. `contextSize` reports 8192; the model variant is "AFM 3 Core Advanced";
`capabilities` include vision, tool calling and guided generation (no
reasoning). `GenerationSchema` is `Codable` but only in its own dialect (it
requires `title` and `x-order` and rejects `type: [..]`), so JSON Schema
must go through `DynamicGenerationSchema`. A prompt made of one phrase
repeated thousands of times trips the *guardrails* before the context
check; varied text produces the context-size error. With a macOS 27
deployment target that error is `LanguageModelError.contextSizeExceeded`;
the same binary built for macOS 26 received the deprecated
`GenerationError.exceededContextWindowSize` instead. Check H: the free-form
schema gave `{}` twice and a decoder failure (`{""algorithm"":"glm",…}`)
once; JSON text gave `{"algorithm": "glm", "lambda": 0.5}` three times.
With rtemislive's full `validate_config` schema (check C2), though, the
same model cut the text at the value's opening quote (`{"algorithm":`),
and it did the same in longer conversations: the detour makes an open
object *possible* on this model, not reliable. That is why rtemislive keeps
the 8k model out of Study mode rather than compacting Study to fit it.

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
