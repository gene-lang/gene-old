# Implementation Tasks

## 1. Runtime Primitives
- [x] 1.1 Expose stdin/stdout helpers needed by interactive CLI loops
  - [x] Add a builtin to flush stdout
  - [x] Add a builtin to read one stdin line and return `nil` on EOF
  - [x] Add a builtin to detect whether stdin/stdout is attached to a TTY if needed by the final CLI loop
- [x] 1.2 Expose Unix signal handler registration
  - [x] Add a builtin to register a callable for `INT`
  - [x] Define shutdown/error behavior for unsupported signals or non-callable handlers

## 2. GeneClaw CLI Entry Path
- [x] 2.1 Add a dedicated CLI loop module
  - [x] Implement prompt/write/read loop using the new runtime builtins
  - [x] Exit cleanly on EOF, `exit`, `quit`, and `SIGINT`
  - [x] Route each turn through `run_agent_envelope`
- [ ] 2.2 Wire CLI mode into `example-projects/geneclaw/src/main.gene`
  - [x] Parse `--cli` and `--session` before normal boot
  - [x] Skip scheduler/server startup when CLI mode is selected
  - [x] Preserve normal server behavior when CLI mode is not selected
  - [x] Keep `main.gene` thin by moving complex CLI-specific logic into `cli.gene`
  - [ ] Move complex Slack-specific boot or handler logic out of `main.gene` when touching those paths
- [x] 2.3 Reuse existing session semantics
  - [x] Map `--session <name>` to `thread_id`
  - [x] Keep workspace/channel defaults aligned with the design doc

## 3. Test Coverage
- [x] 3.1 Add runtime tests for new builtins
  - [x] Flush/readline behavior
  - [x] Signal registration behavior on supported platforms
- [x] 3.2 Add GeneClaw CLI integration tests
  - [x] Basic prompt/response turn
  - [x] Named-session persistence
  - [x] Clean shutdown via signal or EOF

## 4. Validation
- [x] 4.1 Run `openspec validate add-geneclaw-cli-mode --strict`
- [x] 4.2 Run targeted tests for runtime builtins and GeneClaw CLI mode
- [ ] 4.3 Run broader regression coverage as needed
