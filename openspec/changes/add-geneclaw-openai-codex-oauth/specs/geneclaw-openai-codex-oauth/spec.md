## ADDED Requirements

### Requirement: GeneClaw SHALL support OpenAI Codex OAuth bearer configuration

The system SHALL allow GeneClaw's OpenAI provider to be configured with an OAuth bearer token distinct from `OPENAI_API_KEY`.

#### Scenario: OAuth token configured

- **WHEN** the operator configures an OpenAI OAuth bearer token for GeneClaw
- **THEN** GeneClaw selects the Codex OAuth transport for OpenAI inference
- **AND** the existing API-key-based OpenAI behavior remains unchanged when only `OPENAI_API_KEY` is configured

### Requirement: GeneClaw SHALL use the Codex responses transport for OpenAI OAuth inference

When OpenAI OAuth mode is active, the system SHALL send inference requests to the ChatGPT Codex responses backend using the request shape required by that transport.

#### Scenario: Minimal Codex inference request

- **WHEN** GeneClaw sends a prompt using OpenAI OAuth mode
- **THEN** it targets the Codex responses endpoint
- **AND** sends the system prompt via `instructions`
- **AND** encodes the conversation input as OpenResponses message items
- **AND** sends `stream: true`
- **AND** sends `store: false`
- **AND** omits parameters that are known to be unsupported by the Codex backend

### Requirement: GeneClaw SHALL normalize streamed Codex responses into the existing provider contract

The system SHALL parse streamed Codex response events and produce the same normalized content/tool-call structure used by other GeneClaw providers.

#### Scenario: Text-only completion

- **WHEN** the Codex backend returns streamed output text events
- **THEN** GeneClaw assembles the final assistant text into its normal response shape

#### Scenario: Tool-call completion

- **WHEN** the Codex backend returns streamed tool invocation events
- **THEN** GeneClaw returns tool calls in the same internal format used by the existing OpenAI provider path

### Requirement: GeneClaw SHALL preserve actionable Codex transport errors

The system SHALL expose Codex OAuth HTTP errors with status and body so operator debugging does not collapse into generic provider failures.

#### Scenario: Backend rejects malformed Codex request

- **WHEN** the Codex backend returns a non-2xx response
- **THEN** GeneClaw logs or surfaces the HTTP status and raw response body
- **AND** the error remains distinguishable from generic network failures
