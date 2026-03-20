## ADDED Requirements

### Requirement: Interactive REPL Line Editing
When a REPL session is started from an interactive terminal, the REPL SHALL use a readline-compatible input backend that supports terminal line editing without changing REPL evaluation semantics.

#### Scenario: Interactive REPL uses line editor
- **WHEN** a user starts `gene repl` from a TTY
- **THEN** the prompt accepts editable input through a readline-compatible terminal editor
- **AND** submitting the line evaluates the same Gene source that the user entered

#### Scenario: Non-interactive REPL keeps plain input path
- **WHEN** REPL input is provided from a non-interactive stream
- **THEN** the REPL continues to read plain lines without requiring the readline backend

### Requirement: REPL Session History Navigation
Interactive REPL sessions SHALL keep an in-memory history of entered commands so users can recall prior input with standard readline history keys.

#### Scenario: Recall previous command with arrow keys
- **WHEN** a user enters multiple commands in an interactive REPL session and presses the up arrow
- **THEN** the REPL shows an earlier command from the current session history
- **AND** pressing the down arrow moves forward through that history

### Requirement: REPL Reverse History Search
Interactive REPL sessions SHALL expose reverse history search for the current session through `Ctrl-R`.

#### Scenario: Search prior command from current session
- **WHEN** a user presses `Ctrl-R` in an interactive REPL session and types a search term
- **THEN** the REPL shows the most recent matching command from the current session history
