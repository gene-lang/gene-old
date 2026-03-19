# Proposal: Add GeneClaw CLI Mode

## Why

GeneClaw currently runs as an HTTP/Slack service, which makes interactive local testing awkward and makes process-driven automation depend on network endpoints. A direct stdin/stdout CLI mode would let developers and tests drive the existing agent pipeline without standing up the server stack.

## What Changes

- **ADDED**: Gene runtime builtins for line-based stdin reads, stdout flushing, and Unix signal handlers needed by interactive CLI loops
- **ADDED**: A `--cli` entry path for GeneClaw that runs an interactive stdin/stdout loop instead of starting the server/scheduler stack
- **ADDED**: Session mapping from `--session <name>` into GeneClaw's existing `workspace/channel/thread` session model
- **ADDED**: CLI tests that drive GeneClaw through `system/Process/start`
- **ADDED**: A documented known issue that stdout logging noise is tolerated in v1 as long as nothing writes to stdout after `User: ` until that input line is consumed

## Impact

- **Affected specs**: New capability - `geneclaw-cli-mode`
- **Affected code**:
  - Modified: `src/gene/stdlib/core.nim` and/or `src/gene/stdlib/system.nim`
  - Modified: `example-projects/geneclaw/src/main.gene`
  - New or modified: `example-projects/geneclaw/src/cli.gene`
  - New or modified: GeneClaw CLI tests under `tests/`
  - Referenced design doc: `example-projects/geneclaw/docs/cli_mode.md`

## Compatibility Notes

- v1 remains Unix/macOS only because signal handling is Unix-shaped.
- CLI mode must be mutually exclusive with the normal GeneClaw server boot path.
- The runtime logging sink is unchanged in v1; CLI automation syncs on `User: ` rather than assuming stdout is otherwise clean.
