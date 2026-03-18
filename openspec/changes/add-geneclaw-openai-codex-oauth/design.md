## Context

OpenClaw's `openai-codex` provider maps to ChatGPT-backed Codex inference rather than the public `api.openai.com/v1` surface. Live curl probes on March 17, 2026 confirmed the working GeneClaw-compatible path is `POST https://chatgpt.com/backend-api/codex/responses` with bearer auth from the local Codex token source.

Those probes also showed that the Codex backend is not wire-compatible with GeneClaw's current OpenAI chat path:

- it requires `instructions`
- it requires list-form `input`
- it requires `stream: true`
- it rejects `max_output_tokens`
- it succeeds with `store: false`

GeneClaw currently calls `OpenAIClient.chat`, which builds chat-completions style payloads and cannot satisfy the Codex backend contract.

## Goals / Non-Goals

- Goals:
- support OpenAI Codex OAuth bearer tokens in GeneClaw
- keep the existing OpenAI API-key path unchanged
- normalize Codex SSE responses into GeneClaw's current provider contract
- preserve HTTP status/body visibility for Codex failures

- Non-Goals:
- implement browser OAuth login inside GeneClaw
- implement token refresh flow inside GeneClaw
- replace the existing API-key-based OpenAI path
- support every optional OpenResponses field on day one

## Decisions

- Decision: detect Codex mode from explicit OpenAI OAuth-token configuration rather than overloading `OPENAI_API_KEY`.
- Why: the endpoint, required fields, and response format differ materially from the public OpenAI API path.

- Decision: add a dedicated Codex request builder and SSE response parser in `openai_client.nim`.
- Why: the current `chat` request builder is structurally incompatible with the Codex backend.

- Decision: synthesize `instructions` from GeneClaw's system prompt and convert conversation state into OpenResponses message items.
- Why: live probes showed the backend rejects missing `instructions` and scalar `input`.

- Decision: omit parameters that the Codex backend rejects until they are proven safe.
- Why: live probes showed `max_output_tokens` returns `400 Unsupported parameter`.

## Risks / Trade-offs

- Hidden backend contracts may drift.
- Mitigation: keep strict error surfacing and preserve a live curl smoke-check recipe.

- Codex OAuth behavior may diverge from API-key OpenAI behavior in subtle ways.
- Mitigation: isolate Codex behavior behind auth-mode detection and keep the API-key path untouched.

## Migration Plan

1. Add GeneClaw config support for OpenAI OAuth bearer tokens.
2. Implement Codex transport selection and request shaping in the Nim client.
3. Normalize streamed Codex responses back into the current provider interface.
4. Add regression coverage and live smoke verification.

## Open Questions

- Whether `ChatGPT-Account-Id` should always be sent for inference or only when present in the token source.
- Whether GeneClaw should use OpenClaw-parity attribution headers verbatim or introduce GeneClaw-specific attribution values.
