# rtemis-afm

A small local bridge that serves Apple's on-device Foundation Model — the
model behind Apple Intelligence — to [rtemislive](https://live.rtemis.org)
over the OpenAI Chat Completions wire.

It exists because a web page cannot reach the model any other way: the
`FoundationModels` framework is native-only, and macOS's own `fm serve`
refuses every request that comes from a web page. `rtemis-afm` listens on
`http://127.0.0.1:1977`, accepts requests from rtemislive (and any local
development server), and translates them for the framework.

**Requirements:** an Apple silicon Mac, macOS 27 or later, Apple Intelligence
turned on in System Settings. No Apple Developer account, no model download.

## Install and run

One line in Terminal:

```sh
curl -fsSL https://live.rtemis.org/afm.sh | sh
```

That downloads the latest release, verifies its checksum, installs it to
`~/.rtemis/bin/rtemis-afm` and starts it. Next time, run `rtemis-afm`. Leave
the Terminal window open while you chat, and pick **Apple Intelligence** in
rtemislive's chat provider menu. (The script's source is
[`scripts/afm.sh`](scripts/afm.sh).)

With Homebrew:

```sh
brew install rtemis-org/tap/rtemis-afm
rtemis-afm
```

Downloading the release tarball in a browser also works, but Gatekeeper will
say *"Apple could not verify…"* — the binary is signed ad hoc, not notarized.
Either choose *Open Anyway* in System Settings ▸ Privacy & Security, or run
`xattr -d com.apple.quarantine rtemis-afm`. `curl` and Homebrew do not set the
quarantine attribute, which is why the two paths above need neither.

### Command line

```
rtemis-afm                    # serve on 127.0.0.1:1977 (the default)
rtemis-afm --port 1977 --allow-origin https://example.org --verbose
rtemis-afm status             # GET /health of a running bridge; exit 0 if the model is available
rtemis-afm version
```

`--verbose` logs one line per request (method, path, status, tokens in/out,
milliseconds) and the schema keywords it had to ignore. Prompt and completion
text are never logged.

## What it serves

Three endpoints, all on `http://127.0.0.1:1977`:

| Endpoint | Purpose |
|---|---|
| `GET /health` | `{ status, version, model: { id, availability, reason?, context_window } }`. Always `200`; the body says whether chat can work. |
| `GET /v1/models` | One model, `afm`, with `capabilities` (`chat`, `streaming`, `structured_output`, `tools`) and `context_window`. Both fields are this bridge's own — rtemislive reads `capabilities` to decide whether to offer tools. |
| `POST /v1/chat/completions` | OpenAI Chat Completions: `messages`, `stream`, `stream_options.include_usage`, `temperature`, `top_p`, `top_k`, `seed`, `max_tokens` / `max_completion_tokens`, `tools`, `tool_choice`, `response_format`. Unknown fields are ignored, never rejected. |

Notes on the chat endpoint:

- **Streaming** is Server-Sent Events, OpenAI style, ending with `data: [DONE]`.
  `stream` absent means a JSON response (unlike `fm serve`).
- **Tools** round-trip: the model's call comes back as `tool_calls` with
  `finish_reason: "tool_calls"`; post the history back with the `tool` result
  and the model continues. `tool_choice` `"auto"`, `"none"`, `"required"` and a
  forced function all work.
- **Structured output**: `response_format: { type: "json_schema" }` constrains
  generation to the schema. The finished object is sent once, even when
  streaming. `json_object` adds an instruction but does not constrain.
- **Usage** is the framework's own token count (`Response.usage`).
- **Errors** carry an honest status: `400 context_length_exceeded` for a
  prompt that does not fit, `400 content_filter` when guardrails fire,
  `503 model_unavailable` when Apple Intelligence is off, `404` for a model
  other than `afm`. The body is OpenAI's `{ "error": { message, type, code } }`.
- **Probe**: an empty `POST /v1/chat/completions` returns `400` immediately.
  rtemislive's settings indicator uses this to tell "connected" (`400`) from
  `fm serve` (`403`).
- **Context window** is 8,192 tokens (`SystemLanguageModel.contextSize`).
  Long tool schemas eat into it; rtemislive's small-context profile is the
  app-side answer (milestone M4).
- **Origins**: `https://live.rtemis.org`, `http://localhost:*` and
  `http://127.0.0.1:*` are allowed by default; `--allow-origin` adds more.
  Requests from any other web page are served without CORS headers, so the
  browser discards them. There is no authentication, like Ollama; the
  allowlist is the access control.

## Repository tour

Swift Package, no Xcode project: `swift build`, `swift test`, `swift run`.

```
Package.swift                     targets and dependencies (with comments on why each)
Sources/RtemisAFM/                the library — everything unit-testable
  Version.swift                   version, model id, default port
  JSON/JSONValue.swift            a JSON tree, for schemas and tool arguments
  Wire/ChatRequest.swift          OpenAI request types (Decodable)
  Wire/ChatResponse.swift         OpenAI response types (Encodable)
  Wire/BridgeError.swift          an error with an HTTP status and OpenAI type/code
  Adapter/SchemaConverter.swift   JSON Schema → DynamicGenerationSchema → GenerationSchema
  Adapter/TranscriptBuilder.swift messages[] → Transcript + current prompt
  Adapter/BridgeTool.swift        a Tool that throws instead of running (the tool-loop bridge)
  Adapter/ErrorMapper.swift       framework errors → BridgeError
  Engine/RequestPreparer.swift    validation + conversion of a request (pure)
  Engine/GenerationGate.swift     bounded concurrency on the model
  Engine/ChatBackend.swift        the backend protocol and the events it emits
  Engine/FoundationModelsBackend.swift  the real backend: LanguageModelSession
  Server/BridgeServer.swift       Hummingbird application assembly
  Server/Routes.swift             the three endpoints; the chat handler
  Server/CORS.swift               origin rules and CORS middleware
  Server/SSE.swift                event framing and chunk construction
Sources/rtemis-afm/               the CLI (swift-argument-parser)
Sources/afm-spike/                compatibility probe against the real model — see its README
Tests/RtemisAFMTests/             XCTest; the server is tested against a scripted backend
scripts/afm.sh                    the curl | sh installer (copied to rtemislive's public/)
packaging/homebrew/               formula template for rtemis-org/homebrew-tap
.github/workflows/                CI (build + test) and release (tag → signed tarball + tap bump)
docs/maintenance.md               what to re-check when macOS, Xcode or a dependency changes
```

How a chat request flows: `Routes.ChatHandler` reads the body →
`RequestPreparer` validates it and builds a `PreparedChat` (transcript, tools,
options, schema) → `FoundationModelsBackend` opens a `LanguageModelSession`
from the transcript and streams snapshots → the handler renders the resulting
`ChatEvent`s as one JSON object or as SSE chunks.

The one non-obvious piece is tool calling. OpenAI's loop has the *client* run
the tool; the framework runs tools *itself* and waits. `BridgeTool.call`
therefore throws immediately with the arguments the model produced; the
backend catches that, reads every call the model made from the session's
transcript, and answers the HTTP request. The client runs the tool and posts
the whole history back; `TranscriptBuilder` turns `assistant.tool_calls` and
`tool` messages into `.toolCalls` / `.toolOutput` entries, and the model picks
up from there. No session survives between requests.

### Developing

```sh
swift build                       # debug build
swift test                        # unit tests (no Apple Intelligence needed)
swift run afm-spike               # framework compatibility probe (needs the model)
swift run rtemis-afm --verbose    # run from source
```

Built with Xcode 27.0 / Swift 6.4 on macOS 27.0; macOS 27 is also the
deployment target, so nothing is availability-guarded. See
[`docs/maintenance.md`](docs/maintenance.md) before updating anything.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
