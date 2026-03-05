## Why
GeneClaw is currently hardwired to OpenAI-compatible chat even though the runtime already includes an Anthropic client with both API-key and auth-token support. That prevents GeneClaw from using Claude models and leaves provider selection logic duplicated at the application boundary.

## What Changes
- Add explicit LLM provider selection to GeneClaw configuration, keeping OpenAI as the default.
- Add Anthropic configuration support, including API key and auth token modes, model, base URL, and timeout settings.
- Refactor GeneClaw's LLM call path to translate internal history/tools into provider-specific request payloads and normalize provider responses back into GeneClaw's internal `{content, tool_calls}` shape.
- Update GeneClaw documentation to describe Anthropic configuration and provider selection.

## Impact
- Affected specs: `geneclaw-llm-provider`
- Affected code: `example-projects/geneclaw/src/config.gene`, `example-projects/geneclaw/src/agent.gene`, `example-projects/geneclaw/src/tools.gene`, `example-projects/geneclaw/README.md`
