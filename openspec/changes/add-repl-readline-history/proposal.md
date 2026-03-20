# Proposal: Add Readline History Support To REPL

## Why

Gene's REPL currently reads lines directly from the terminal, so users cannot navigate prior commands with the arrow keys or search session history with `Ctrl-R`. This makes iterative debugging slower than a typical interactive shell and is especially awkward now that the REPL supports persistent session state and repl-on-error workflows.

## What Changes

- Add a readline-compatible input path for interactive REPL sessions.
- Enable in-session command history navigation with the up and down arrow keys.
- Enable reverse history search with `Ctrl-R` during interactive REPL input.
- Preserve the current plain line-reading behavior for non-interactive input and environments where the readline backend is unavailable.

## Impact

- Affected specs: `repl`
- Affected code: `src/gene/repl_session.nim`, `src/commands/repl.nim`, build configuration in `gene.nimble` or supporting Nim modules, `tests/test_repl.nim`
