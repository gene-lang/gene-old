# GeneClaw CLI Mode Specification

## ADDED Requirements

### Requirement: Expose Runtime Primitives For Interactive CLI Loops

The system SHALL expose the Gene-level runtime primitives required to implement a line-oriented interactive CLI loop.

#### Scenario: Flush stdout explicitly

- **GIVEN** a Gene program that writes a partial prompt to stdout
- **WHEN** the flush builtin is called
- **THEN** the buffered stdout data is made visible to pipe-based consumers immediately

#### Scenario: Read one line from stdin

- **GIVEN** stdin contains a newline-terminated line
- **WHEN** the readline builtin is called
- **THEN** the line content is returned without the trailing newline

#### Scenario: Detect EOF while reading stdin

- **GIVEN** stdin is exhausted
- **WHEN** the readline builtin is called
- **THEN** `nil` is returned

#### Scenario: Register a SIGINT handler

- **GIVEN** the program is running on a supported Unix-like platform
- **WHEN** `(on_signal "INT" handler)` is called with a callable handler
- **THEN** the runtime registers that handler for `SIGINT`

### Requirement: Provide A Dedicated GeneClaw CLI Entry Path

The system SHALL provide a CLI mode for GeneClaw that runs an interactive stdin/stdout loop instead of the normal server/scheduler boot path.

#### Scenario: Start interactive CLI mode

- **GIVEN** GeneClaw is launched with `--cli`
- **WHEN** startup argument parsing completes
- **THEN** GeneClaw initializes only the pieces needed for CLI execution
- **AND** it does not start the HTTP server, Slack socket mode, or scheduler loop

#### Scenario: Process one CLI turn through the normal agent pipeline

- **GIVEN** CLI mode is active
- **WHEN** the user enters a non-empty line
- **THEN** the CLI loop calls `run_agent_envelope`
- **AND** the assistant response is written to stdout

#### Scenario: Exit CLI mode cleanly

- **GIVEN** CLI mode is active
- **WHEN** stdin reaches EOF, the user types `exit` or `quit`, or the process receives `SIGINT`
- **THEN** the CLI loop terminates
- **AND** GeneClaw exits without falling through into the normal server boot path

### Requirement: Reuse Existing Session Semantics In CLI Mode

The system SHALL map CLI session names onto GeneClaw's existing workspace/channel/thread session model.

#### Scenario: Default CLI session

- **GIVEN** GeneClaw is launched with `--cli` and no `--session`
- **WHEN** a turn is processed
- **THEN** `run_agent_envelope` receives `workspace_id = "default"`, `channel_id = "cli"`, and `thread_id = ""`

#### Scenario: Named CLI session

- **GIVEN** GeneClaw is launched with `--cli --session my-test`
- **WHEN** a turn is processed
- **THEN** `run_agent_envelope` receives `thread_id = "my-test"`
- **AND** the resulting session id is derived by `build_session_id("default", "cli", "my-test")`

### Requirement: Support Prompt-Based CLI Automation

The system SHALL support process-driven automation of GeneClaw CLI mode through a stable prompt token.

#### Scenario: Synchronize on the prompt token

- **GIVEN** a test drives GeneClaw CLI through `system/Process/start`
- **WHEN** the CLI loop becomes ready for the next input line
- **THEN** it writes `User: ` to stdout as the synchronization token

#### Scenario: Tolerate stdout logging noise in v1

- **GIVEN** runtime or application logs may still be written to stdout
- **WHEN** CLI automation reads until the next `User: ` token
- **THEN** the consumer may receive additional stdout text outside the prompt/response flow
- **AND** the documented guarantee is limited to not writing additional stdout after `User: ` until that input line is consumed
