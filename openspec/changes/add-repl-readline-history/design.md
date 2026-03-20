## Context

The current REPL loop prints a prompt and calls `readLine` on `/dev/tty` or `stdin`. That path is simple and works for scripts, but it does not provide terminal line editing, history navigation, or reverse search. The requested behavior maps directly to the feature set of readline-compatible libraries, but the REPL must continue to function in non-interactive contexts and on systems where such a library is not linked.

## Goals / Non-Goals

Goals:
- Use a readline-compatible backend for interactive REPL sessions.
- Support up/down history navigation within the active REPL session.
- Support `Ctrl-R` reverse history search within the active REPL session.
- Keep existing behavior for non-interactive/scripted REPL execution.
- Degrade gracefully to the current line reader when readline support is unavailable.

Non-Goals:
- Persist history across separate REPL processes.
- Add custom keybinding configuration.
- Change REPL evaluation semantics, scope behavior, or repl-on-error control flow.

## Decisions

- **Backend split**: Keep `run_repl_script` unchanged and limit readline integration to interactive `run_repl_session` input handling.
- **Session-scoped history**: History lives in memory for the current REPL session only. Commands entered in `gene repl`, `($repl)`, and repl-on-error sessions participate in that session's history independently.
- **History filtering**: Record trimmed non-empty entries, but suppress immediate consecutive duplicates so reverse search and arrow-key recall stay useful.
- **Fallback behavior**: If the process is not attached to a TTY, or the readline backend cannot be used on the current build, the REPL continues to use the existing prompt plus `readLine` path.
- **Minimal surface area**: Add a small input abstraction in the REPL module or a dedicated helper module so the VM and compiler remain unchanged.

## Risks / Trade-offs

- **Build portability**: Linking readline differs across macOS and Linux. The implementation should isolate platform-specific linkage and avoid breaking non-interactive builds.
- **Terminal behavior**: Readline owns prompt rendering and input echo for interactive sessions, so prompt handling must not double-print.
- **History quality**: Suppressing blank lines and immediate duplicates improves recall, but it means the session history is a normalized view of executed commands rather than a byte-for-byte transcript of raw terminal input.

## Migration Plan

1. Add a readline-backed interactive reader abstraction with a plain-reader fallback.
2. Route interactive REPL sessions through that abstraction while preserving current behavior for scripted/non-interactive sessions.
3. Add tests for the history abstraction and any fallback behavior that can be exercised non-interactively.
4. Update build configuration or conditional compilation to link the backend without breaking environments that do not provide readline.
