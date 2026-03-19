## Context

The reviewed CLI mode design intentionally reuses `run_agent_envelope` so the interactive path shares the same session, memory, tool, and attachment semantics as HTTP/Slack execution. The missing pieces are lower-level runtime primitives for stdin/stdout/signal handling and a clean entry point in GeneClaw's startup flow.

## Goals

- Add the minimum runtime surface needed to implement an interactive stdin/stdout loop in Gene
- Keep GeneClaw CLI behavior aligned with the existing agent pipeline
- Make CLI mode easy to drive from `system/Process/start` integration tests

## Non-Goals

- Streaming token output
- PTY emulation or rich terminal UI
- Reworking the runtime logging sink in v1
- Windows signal portability in v1

## Design Decisions

### Runtime Builtins

- `flush` should explicitly flush `stdout`.
- `readline` should read a single line from `stdin` and return `nil` on EOF.
- `on_signal` should register a Gene callable for supported Unix signals, starting with `INT`.
- If `isatty` is needed for prompt suppression in pipe mode, it should be exposed as a small builtin instead of inlining platform checks into GeneClaw.

### CLI Control Flow

- `main.gene` must branch into CLI mode before the normal server/scheduler startup path.
- `main.gene` should remain a thin bootstrap entrypoint. Complex command-line control flow belongs in `cli.gene`, and complex Slack-specific boot/handler logic should continue moving into dedicated modules instead of accumulating in `main.gene`.
- CLI turns call `run_agent_envelope` directly; the CLI loop must not duplicate LLM/tool orchestration logic.
- `--session <name>` maps to `thread_id`, which means session ids still flow through `build_session_id(workspace_id, channel_id, thread_id)`.

### Protocol Contract

- `User: ` is the synchronization token for automation.
- v1 tolerates unrelated stdout lines outside the prompt/response flow because logging still writes to stdout.
- The critical behavioral guarantee is narrower: once `User: ` is printed, nothing else should write to stdout until that input line is consumed.

### Shutdown Model

- EOF, `exit`, and `quit` exit the CLI loop normally.
- `SIGINT` exits via the registered signal handler.
- CLI mode should return control to `main.gene`, which immediately exits instead of falling through into the server boot path.

## Risks / Trade-offs

- Signal registration from inside the VM adds runtime-global state; tests must avoid leaking handlers across cases.
- Leaving logging on stdout keeps implementation scope small but weakens the protocol for consumers that expect a pristine stream.
- Prompt suppression in pipe mode may need `isatty`; without it, v1 may emit a trailing prompt before EOF is observed.
