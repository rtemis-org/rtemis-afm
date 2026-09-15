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

**Schemas.** `GenerationSchema` is `Codable`, but decodes only its own
dialect (`title` and `x-order` required; no `type: [..]`). If a future SDK
accepts plain JSON Schema, `SchemaConverter` can shrink to a passthrough
with a fallback. Keywords currently ignored (`pattern`, `format`,
`additionalProperties: {…}`, `allOf` with several members, `if`/`then`) are
candidates as `DynamicGenerationSchema` gains initializers;
`GenerationGuide.pattern(Regex)` already exists for strings.

**Tool calling.** Reading all parallel calls from `session.transcript`
depends on `transcriptErrorHandlingPolicy = .preserveTranscript` keeping
the `.toolCalls` entry after `BridgeTool` throws (check B in the spike). If
a release changes that, the fallback is the single intercepted call.
`toolCallingMode: .required` is what `tool_choice: "required"` and forced
functions rely on.

**Context window.** `SystemLanguageModel.contextSize` reports 8192 on
macOS 27.0. If Apple raises it
(or exposes a larger variant — `SystemLanguageModel.Variant` exists now),
`/v1/models` picks it up automatically; rtemislive's small-context profile
should read the value rather than assume 8k.

**Vision.** The macOS 27 model accepts image attachments
(`Transcript.Segment.attachment`). The bridge rejects `image_url` parts with
`400` and does not advertise `vision`; adding it means decoding data URLs
into `Transcript.ImageAttachment` in `TranscriptBuilder` and adding
`"vision"` to `capabilities` (rtemislive keys `supportsVision` off that).

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
- The repository is private at the time of writing. `afm.sh` resolves the
  latest release through the unauthenticated GitHub API and downloads
  release assets, which needs a **public** repository (as does free macOS
  CI). Make it public before the first release.
- rtemislive's Help page says `brew install rtemis/tap/rtemis-afm`, which
  would need a GitHub account named `rtemis`. The formula template and the
  release workflow target `rtemis-org/homebrew-tap` (install line:
  `brew install rtemis-org/tap/rtemis-afm`). Align one or the other.
- `scripts/afm.sh` is the source; copy it to rtemislive's `public/afm.sh` on
  every change (the Help page links to the deployed URL). The Help page
  currently says "macOS 26 or later"; the bridge needs 27.
- Bump `Sources/RtemisAFM/Version.swift` and `CHANGELOG.md` before tagging;
  the release workflow refuses a tag that does not match the version constant.

## Known limitations (v0.1)

- Text only: no images in either direction.
- `json_object` asks for JSON but cannot enforce it (no schema to constrain to).
- `finish_reason: "length"` is inferred from the token cap, not reported by
  the framework.
- Guardrails fire on odd inputs (a phrase repeated thousands of times), and
  their message is surfaced verbatim as `400 content_filter`.
