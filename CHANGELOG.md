# Changelog

## 0.1.0 — unreleased

First version: `/health`, `/v1/models`, `/v1/chat/completions` (JSON and
SSE), tool calling with a stateless round trip, `response_format`
(`json_schema`, `json_object`), OpenAI-style errors with honest status codes,
CORS allowlist, generation gate, cancel on disconnect, `afm.sh` installer,
Homebrew formula template, CI and release workflows. Requires macOS 27;
built against macOS 27.0 / Xcode 27.0.

Open objects (`{"type": "object"}` without `properties`) in tool parameters
and structured output are generated as JSON text and parsed back, so a
free-form settings block can carry keys instead of always being `{}`;
`json_object` is enforced the same way (spike check H).

Vision: `image_url` parts on user messages (as `data:` URIs) reach the
model, on the prompt and in the rebuilt history; `/v1/models` advertises
`vision` when the framework reports the capability (spike check V).
