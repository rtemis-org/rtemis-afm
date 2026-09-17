# Maintenance notes

`rtemis-afm` sits on three things that move: Apple's `FoundationModels`
framework (ships with macOS, surface changes with each SDK), Hummingbird
(the HTTP server), and the OpenAI wire as rtemislive's SDK speaks it. This
file lists what to re-check when any of them changes, and the places in the
code that encode today's assumptions.

State of the world when this was written: **macOS 27.0 (26A428), Xcode 27.0,
Swift 6.4, Hummingbird 2.26.0, swift-argument-parser 1.8.2, swift-log 1.15.1,
rtemislive `devel` — 15 September 2026.**

## After a macOS or Xcode update

1. Run `swift run afm-spike`. Every check must pass; its README explains
   what each one protects.
2. Run `swift test`.
3. Diff the SDK's module interface against the code's expectations:
   ```sh
   SDK=$(xcrun --sdk macosx --show-sdk-path)
   IF="$SDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
   grep -n "case " "$IF" | grep -i "error"                 # error cases → ErrorMapper
   grep -n "public init" "$IF" | grep DynamicGenerationSchema  # builders → SchemaConverter
   grep -n "case " "$IF" | grep -A0 "Transcript"           # entry/segment kinds → TranscriptBuilder
   grep -n "deprecated\|obsoleted" "$IF"                   # anything we still call?
   ```
4. Decide whether the floor in `Package.swift` (`macOS "27.0"`) should
   rise. There are no `#available` guards: anything the new SDK adds is
   either adopted outright (and the floor raised) or left alone.

### Things worth watching, by area

**Errors.** Which error enum the system model throws depends on the
*deployment target*, not the OS: built for macOS 26 it throws the deprecated
`LanguageModelSession.GenerationError`; built for macOS 27 it throws
`LanguageModelError` (spike check F2 prints the type). The bridge targets 27
and handles only the new enum. If the floor ever drops back, the old enum
needs a mapping again.

**Context overflow with tools.** With tools attached, the macOS 27.0
framework reports an oversized transcript through `GenerativeError`, an
internal type absent from the public interface, instead of
`LanguageModelError.contextSizeExceeded`. `ErrorMapper` recognizes its
message ("Provided N tokens, but the maximum allowed is M") and maps it to
`400 context_length_exceeded`; spike check F3 prints the type. If a later
SDK throws the public error there too, the message match becomes dead code.

**Schemas.** `GenerationSchema` is `Codable`, but decodes only its own
dialect (`title` and `x-order` required; no `type: [..]`). If a future SDK
accepts plain JSON Schema, `SchemaConverter` can shrink to a passthrough
with a fallback. Keywords currently ignored (`pattern`, `format`,
`additionalProperties: {…}`, `allOf` with several members, `if`/`then`) are
candidates as `DynamicGenerationSchema` gains initializers;
`GenerationGuide.pattern(Regex)` already exists for strings.

**Open objects.** A schema `{"type": "object"}` with no `properties` (how
rtemislive's config tools declare their free-form `hyperparameters` block)
has no guided-generation form: `DynamicGenerationSchema` needs properties,
and the framework's free-form `GeneratedContent.generationSchema` ("Any
legal JSON") misbehaves on macOS 27.0 — the model emits `{}` or the
constrained decoder doubles the key quotes and fails. The bridge therefore
asks for such values as JSON *text* in a string and parses them back
(`OpenValue`, `SchemaConverter`, `BridgeTool.wireArguments`,
`FoundationModelsBackend.wireContent`). `json_object` uses the same path with
the root as the open value. Spike check H compares both encodings on the
real model; when it reports that free-form generation works, the converter
can map open objects to `GeneratedContent.generationSchema` and the detour
can go. The hint text (`OpenValue.hint`) carries no example on purpose: the
model copies an example's keys.

**Context options.** `streamResponse` takes a `ContextOptions` (macOS 27)
with `includeSchemaInPrompt` and `reasoningLevel` (`.light`/`.moderate`/
`.deep`). The bridge leaves both at their defaults. `includeSchemaInPrompt:
false` might reduce the prompt cost of structured output; worth measuring
against `usage.prompt_tokens` before adopting it.

**Tool calling.** Reading all parallel calls from `session.transcript`
depends on `transcriptErrorHandlingPolicy = .preserveTranscript` keeping
the `.toolCalls` entry after `BridgeTool` throws (check B in the spike). If
a release changes that, the fallback is the single intercepted call.
`toolCallingMode: .required` is what `tool_choice: "required"` and forced
functions rely on.

**Context window.** `SystemLanguageModel.contextSize` reports 8192 on
macOS 27.0 (re-checked 2026-09-17 on 26A428; the only on-device variant is
`.core3`, "AFM 3 Core Advanced"). If Apple raises it, `/v1/models` picks it
up automatically. rtemislive reads `context_window` from there and keeps a
model below 32k out of Study mode (Chat is unaffected); a larger on-device
model passes that gate with no change on either side. The larger model
Apple does ship, `PrivateCloudComputeLanguageModel` (32,768 tokens, vision,
tools, reasoning), is not an option for this bridge: it needs a managed
entitlement Apple grants for App Store distribution only, and an
ad-hoc-signed binary gets `ModelManagerError 1046` (spike README,
2026-09-17). The 32k figure comes
from measuring a Study round trip on this bridge (~15k tokens with the full
tool set), and the 8k model was also tried with compacted schemas and
digested tool results: a 3B model still could not fill a config through
them reliably, which is why the app gates rather than compacts.

**Vision.** The macOS 27 model accepts image attachments, and the bridge
carries them: `image_url` parts on `user` messages are decoded from their
`data:` URI by `ImageDecoder` into `Transcript.ImageAttachment` — into the
`.prompt` entry's segments for history, onto the `Prompt` for the final
message (`FoundationModelsBackend.prompt`). `vision` is advertised on
`/v1/models` when `model.capabilities` reports it, and rtemislive shows the
attach button off that field. Remote (`http`) image URLs are `400
unsupported`: the bridge does not fetch on the page's behalf. An image costs
at most 147 input tokens whatever its size (spike check V has the table).

**Reasoning.** `Transcript.Entry.reasoning` and
`ContextOptions.reasoningLevel` exist for models that reason
(`PrivateCloudComputeLanguageModel`); the on-device model reports no
reasoning capability. Nothing to do unless the bridge grows a second model.

**Other models.** The `LanguageModel` protocol (macOS 27) lets a
`LanguageModelSession` run on `PrivateCloudComputeLanguageModel` or a
third-party package. `FoundationModelsBackend` is written against
`SystemLanguageModel` specifically (availability, `contextSize`,
`variant`); serving a second model would mean generalizing it and adding a
second `/v1/models` entry.

**Apple's own utilities.** `apple/foundation-models-utilities` (Apache-2.0)
contains `ChatCompletionsLanguageModel`, the *reverse* adapter (framework →
any chat-completions server). Its transcript↔messages mapping was used as a
reference for `TranscriptBuilder`; if Apple ever ships the forward direction
(server from a `LanguageModel`), most of this package becomes a thin wrapper.

## After a Hummingbird update

- The chat handler uses `RequestBody.consumeWithCancellationOnInboundClose`
  and must pass it the *unread* body (it reads request parts itself to
  notice the close; handing it a consumed body crashed with "Deinited
  NIOAsyncSequenceProducer.Source without calling source.finish()" on
  2.26.0). It also leaves the connection unusable afterwards, which is why
  chat responses carry `Connection: close` and the server tests use the
  reconnecting `.ahc` client rather than `.live`.
- `ResponseBody { writer in … }` is how SSE is streamed; `writer.finish(nil)`
  must be called once.
- Middleware runs for unmatched routes too, which the CORS preflight relies on.

## After an OpenAI wire / rtemislive SDK change

- rtemislive uses `@ai-sdk/openai-compatible`. Fields it sends are decoded in
  `ChatRequest.swift`; anything new is ignored until declared there.
- The probe contract (`400` on an empty POST) and the `capabilities` field on
  `/v1/models` are contracts with `src/lib/chat/providers/afm.ts` in
  rtemislive. Change both sides together.
- Tool-call ids: the bridge echoes the framework's ids (UUIDs); clients send
  them back verbatim and `TranscriptBuilder` uses whatever it gets.

## Distribution

- CI and release run on the `xcode-27` GitHub runner label (public preview,
  macOS 27, arm64). The GA `macos-26` image has only Xcode 26.x, whose SDK
  cannot compile this package. Move to `macos-27` when it becomes a stable
  label.
- The repository is public (since 2026-09-15). Keep it so: `afm.sh`
  resolves the latest release through the unauthenticated GitHub API and
  downloads release assets, and free macOS CI minutes depend on it too.
- The tap is `rtemis-org/homebrew-tap` (public; created 2026-09-15), install
  line `brew install rtemis-org/tap/rtemis-afm`. It holds only a README until
  the first release; the release workflow writes `Formula/rtemis-afm.rb`
  and needs the `TAP_GITHUB_TOKEN` secret (fine-grained PAT, Contents:
  write on the tap) to push there. After the first release, run
  `brew audit --strict --online rtemis-org/tap/rtemis-afm` once.
- The formula's `depends_on macos: :golden_gate` is Homebrew's codename for
  macOS 27 (checked against Homebrew 7.0.2, `Library/Homebrew/macos_version.rb`).
  If the minimum macOS ever changes, change the codename with it. The formula
  has no `version` line on purpose: Homebrew reads `0.1.0` from the tarball
  name, and `brew audit --strict` rejects an explicit one as redundant.
- `scripts/afm.sh` is the source; copy it to rtemislive's `public/afm.sh` on
  every change (the Help page links to the deployed URL).
- Bump `Sources/RtemisAFM/Version.swift` and `CHANGELOG.md` before tagging;
  the release workflow refuses a tag that does not match the version constant.

## Known limitations (v0.1)

- Images in, not out: the model cannot generate one, and only `data:` URIs
  are accepted.
- `json_object` is enforced by generating one string and parsing it; if the
  model writes something that is not a JSON object, that text is returned
  as it was written.
- `finish_reason: "length"` is inferred from the token cap, not reported by
  the framework.
- Guardrails fire on odd inputs (a phrase repeated thousands of times), and
  their message is surfaced verbatim as `400 content_filter`.
