## ADDED Requirements

### Requirement: GeneClaw SHALL support configurable LLM providers
GeneClaw SHALL allow the active LLM provider to be selected via configuration while preserving OpenAI as the default provider.

#### Scenario: OpenAI remains the default
- **WHEN** `GENECLAW_LLM_PROVIDER` is unset
- **THEN** GeneClaw SHALL use the OpenAI provider path
- **AND** existing `OPENAI_*` configuration SHALL continue to work without changes

#### Scenario: Anthropic provider is selected
- **WHEN** `GENECLAW_LLM_PROVIDER` is set to `anthropic`
- **THEN** GeneClaw SHALL use the Anthropic provider path
- **AND** it SHALL read Anthropic-specific configuration values for credentials, model, base URL, and timeout

### Requirement: GeneClaw SHALL accept Anthropic API key or auth token credentials
GeneClaw SHALL support Anthropic authentication using either an API key or an auth token.

#### Scenario: Anthropic API key is configured
- **WHEN** the Anthropic provider is selected and `ANTHROPIC_API_KEY` is set
- **THEN** GeneClaw SHALL be able to create an Anthropic client and make LLM requests

#### Scenario: Anthropic auth token is configured
- **WHEN** the Anthropic provider is selected and `ANTHROPIC_AUTH_TOKEN` is set
- **THEN** GeneClaw SHALL be able to create an Anthropic client and make LLM requests

### Requirement: GeneClaw SHALL translate its internal agent format into provider-specific requests
GeneClaw SHALL preserve its internal agent loop format while translating requests to the selected provider's API schema.

#### Scenario: Anthropic request translation includes system prompt and tools
- **WHEN** GeneClaw sends a request through the Anthropic provider
- **THEN** it SHALL send the system prompt using Anthropic's top-level `system` field
- **AND** it SHALL translate tool definitions into Anthropic `tools` entries with `input_schema`

#### Scenario: Anthropic request translation includes prior tool execution
- **WHEN** GeneClaw sends a follow-up request after a tool call
- **THEN** prior assistant tool requests SHALL be translated into Anthropic `tool_use` blocks
- **AND** prior tool outputs SHALL be translated into Anthropic `tool_result` blocks

### Requirement: GeneClaw SHALL normalize provider responses into its internal response shape
GeneClaw SHALL normalize provider responses into the internal `{content, tool_calls}` structure used by the agent loop.

#### Scenario: Anthropic text response is normalized
- **WHEN** the Anthropic provider returns assistant text without tool calls
- **THEN** GeneClaw SHALL return that text in `content`
- **AND** it SHALL return an empty `tool_calls` array

#### Scenario: Anthropic tool_use blocks are normalized
- **WHEN** the Anthropic provider returns one or more `tool_use` blocks
- **THEN** GeneClaw SHALL convert each block into an internal tool call entry with an id, function name, and JSON-encoded arguments
- **AND** the agent loop SHALL be able to dispatch those tool calls without provider-specific branching

### Requirement: GeneClaw SHALL preserve mock-mode and error behavior across providers
GeneClaw SHALL keep the existing user-visible mock-mode and error behavior for whichever provider is selected.

#### Scenario: Selected provider is missing credentials
- **WHEN** the selected provider has no usable credentials configured
- **THEN** GeneClaw SHALL return its mock-mode response instead of attempting a live LLM request

#### Scenario: Selected provider returns an API or network error
- **WHEN** the selected provider client returns an error object
- **THEN** GeneClaw SHALL log the failure
- **AND** it SHALL return an `LLM error: ...` response with no tool calls
