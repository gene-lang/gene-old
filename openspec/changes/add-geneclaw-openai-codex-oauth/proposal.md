## Why

GeneClaw currently supports OpenAI API keys against the public OpenAI API and Anthropic OAuth-style bearer tokens, but it does not support ChatGPT/Codex OAuth bearer tokens for OpenAI. OpenClaw already supports that auth mode, and live probes confirmed it requires a distinct ChatGPT Codex transport rather than GeneClaw's current chat-completions path.

## What Changes

- Add GeneClaw/OpenAI config support for an OAuth bearer token distinct from `OPENAI_API_KEY`.
- Route OpenAI OAuth-backed requests through the ChatGPT Codex responses transport instead of the existing chat-completions transport.
- Normalize streamed Codex responses back into GeneClaw's existing provider response shape.
- Preserve HTTP status/body details for Codex transport failures.

## Impact

- Affected specs: `geneclaw-openai-codex-oauth`
- Affected code: `example-projects/geneclaw/src/config_schema.gene`, `example-projects/geneclaw/src/llm_provider.gene`, `src/genex/ai/openai_client.nim`, `src/genex/ai/bindings.nim`, provider tests
