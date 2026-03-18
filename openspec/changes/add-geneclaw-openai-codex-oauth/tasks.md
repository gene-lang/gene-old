## 1. Configuration and transport

- [x] 1.1 Extend GeneClaw config to accept an OpenAI OAuth/Codex auth token without regressing existing API-key behavior.
- [x] 1.2 Add a Codex-specific OpenAI transport path in the Nim client for `https://chatgpt.com/backend-api/codex/responses`.
- [x] 1.3 Encode Codex-required request fields: `instructions`, list-form `input`, `stream: true`, and `store: false`.
- [x] 1.4 Avoid sending request parameters that the Codex backend rejects.

## 2. Response handling

- [x] 2.1 Parse streamed Codex SSE events into the existing GeneClaw normalized response shape.
- [x] 2.2 Normalize Codex tool calls into the same internal format used by the current OpenAI provider path.
- [x] 2.3 Preserve actionable Codex HTTP status/body errors through the Nim bridge and GeneClaw logs.

## 3. Verification

- [x] 3.1 Add regression tests for config detection and request building.
- [x] 3.2 Add regression tests for streamed Codex response normalization.
- [x] 3.3 Validate with targeted Nim/Gene tests plus a live curl smoke check using the local Codex token source.
