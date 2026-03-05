## Context
GeneClaw stores conversation history in an OpenAI-oriented internal format:
- a system prompt as a `system` message
- assistant tool requests via `assistant.tool_calls`
- tool outputs via `tool` role messages with `tool_call_id`

That shape matches the current OpenAI client usage, but Anthropic's Messages API uses a different request contract:
- system prompt is a top-level `system` field
- messages use content blocks rather than plain strings
- tool definitions use `{name, description, input_schema}` rather than OpenAI's `type=function` wrapper
- tool execution is represented by `tool_use` and `tool_result` content blocks

## Goals
- Add Anthropic support without changing the rest of GeneClaw's tool execution loop.
- Keep OpenAI behavior backward compatible by default.
- Reuse the existing Anthropic client in `genex/ai` rather than adding another HTTP client path.

## Non-Goals
- Streaming support
- Responses API support for Anthropic
- Cross-provider history persistence changes in the database schema

## Design
Introduce a provider adapter layer inside `agent.gene`.

### Provider selection
- Add `GENECLAW_LLM_PROVIDER` with default `openai`.
- OpenAI continues to use `OPENAI_*` settings.
- Anthropic uses `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`, plus `ANTHROPIC_MODEL`, `ANTHROPIC_BASE_URL`, and `ANTHROPIC_TIMEOUT_MS`.

### Request building
Keep the in-memory/history format unchanged and translate only at call time.

- OpenAI adapter:
  - reuse the current `messages` array and current tool schema.
- Anthropic adapter:
  - move the system prompt into top-level `system`
  - convert text messages into content blocks
  - convert tool specs into Anthropic `tools` entries with `input_schema`
  - convert prior assistant `tool_calls` into `tool_use` blocks
  - convert prior `tool` role messages into user `tool_result` blocks

### Response normalization
Both providers return a normalized internal map:
- `content`: assistant text content as a string
- `tool_calls`: array of tool calls in OpenAI-compatible internal shape

Anthropic `tool_use` blocks will be converted to:
- `id`: Anthropic tool-use id
- `function.name`: tool name
- `function.arguments`: JSON string of the tool input map

Anthropic non-text content blocks that are not tool calls are ignored for v1 unless they contain assistant text.

### Errors and mock mode
- Missing credentials for the selected provider keep the current mock-mode behavior.
- Provider transport/API errors are normalized into the existing `LLM error: ...` response path.
