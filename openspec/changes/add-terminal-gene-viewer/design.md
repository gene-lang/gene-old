## Context

The current CLI can parse, compile, and execute Gene source, but it does not provide an interactive way to browse large structured data files. Gene logs are a particularly important case because they are often append-only, may contain many top-level forms, and typically require drilling into nested arrays, maps, and Gene nodes one entry at a time.

The parser already exposes `read_stream`, which makes it possible to consume top-level forms incrementally. That gives the viewer a workable foundation for opening large files without building a full in-memory tree first.

## Goals / Non-Goals

- Goals:
  - Open large Gene files in a terminal TUI without dumping the full document to stdout.
  - Support arrow-key navigation for moving within a container and drilling into nested values.
  - Support quick type-ahead navigation within the current container.
  - Support quick inline edits for simple scalar values without leaving the viewer.
  - Allow the user to hand the current file off to an external terminal editor and return to the viewer afterward.
  - Show the current file path and logical node path at the top of the screen.
  - Show a stable function-key legend at the bottom of the screen.
  - Treat append-only multi-form Gene logs as a browsable root sequence.
  - Avoid recursive eager parsing of unopened descendants.
- Non-Goals:
  - Embedded split-pane editing inside the ncurses layout
  - Editing arrays, maps, genes, or other structural nodes inline
  - Live log tailing
  - Search, filtering, or query language support
  - Syntax highlighting or rich text formatting
  - Remote viewing over LSP or web UIs

## Decisions

- Decision: add a top-level `gene view <file>` command.
  - Rationale: browsing a file is user-facing CLI functionality, and the current binary already hosts other developer tools such as `parse`, `compile`, and `gir`.

- Decision: use an ncurses-backed full-screen UI behind a thin terminal adapter.
  - Rationale: arrow keys, function keys, window resize handling, and screen repaint behavior are all easier to manage through a curses-style backend than by hand-rolling raw ANSI control in each viewer module.
  - Consequence: implementation may add a new dependency or system-library linkage requirement.

- Decision: represent the opened document as either a single parsed root value or a synthetic root sequence.
  - Rationale: normal `.gene` data files may contain one structured root value, while log files may contain many top-level forms. A synthetic root lets the same navigation model work for both without inventing a separate log mode.

- Decision: index top-level values eagerly, expand descendants lazily.
  - Rationale: full recursive parsing is the wrong default for large files. The viewer should stream the file once to identify top-level entries and create lightweight row summaries, then parse child collections only when the user enters them.
  - Consequence: nested random access is still bounded by the cost of parsing the selected subtree, but unopened branches stay cheap.

- Decision: keep navigation state as a stack of frames.
  - Rationale: each frame can store the current node reference, scroll offset, and selected row. This makes left/right navigation and path rendering straightforward and allows the viewer to restore the parent selection after backing out of a child node.
  - Consequence: jumping back to the root container can be implemented by truncating the frame stack to its first frame, which preserves the existing root selection.
  - Consequence: quit confirmation can live alongside the same view state so the first `Ctrl-C` can update status text without tearing down the session.

- Decision: treat printable typing as a short-lived navigation buffer.
  - Rationale: the viewer already presents a flat list of children in the current container, so quick jumps should work without introducing a separate search mode.
  - Consequence: the state model needs a buffered query string plus a recent-input timestamp so typing within a short window extends the same query while idle time starts a new query.

- Decision: reserve footer function keys for stable session controls.
  - Initial legend:
    - `Esc` root
    - `F1` help
    - `F2` or `Ctrl-E` edit in external editor
    - `F5` reload from disk
    - `F10` quit
  - Rationale: the user explicitly asked for function keys on the bottom of the screen, and these three actions are the minimum useful stable controls.

- Decision: implement editing as an external-editor handoff instead of embedding a terminal editor in the lower half of the ncurses screen.
  - Rationale: the current viewer and terminal editors such as `nvim` both need full ownership of the TTY. Closing curses, launching the editor, and reopening the viewer keeps the implementation simple and robust.
  - Consequence: the first version edits the whole file, not an isolated subtree buffer, and uses the current node only to choose the initial cursor location.

- Decision: add a separate inline-edit mode for simple scalar values only.
  - Supported initial value kinds:
    - numbers
    - `true` / `false`
    - `nil`
    - strings
    - symbols and complex symbols
  - Rationale: the viewer already tracks exact source spans for scalar nodes, so replacing a single token in place is much cheaper than handing off to a full editor for trivial edits.
  - Consequence: the model needs explicit scalar editability classification beyond its current color buckets.

- Decision: save inline edits by replacing the selected source span in the backing file, then reloading the document.
  - Rationale: this reuses the existing reload and path-restore behavior instead of mutating the in-memory tree in place.
  - Consequence: save must validate that the edited text is a single legal scalar token of a supported kind before writing the file.

- Decision: use `Tab` to enter inline edit mode, `Enter` to save, and `Esc` to cancel while editing.
  - Rationale: the user explicitly requested `Tab` and `Enter`, and `Esc` is the lowest-friction cancel path in a terminal UI.
  - Consequence: `Esc` has mode-dependent meaning: cancel while editing, otherwise return to root.
  - Consequence: `Tab` also has mode-dependent meaning: start inline edit for supported scalars, otherwise fall back to the existing external-editor handoff.

## Risks / Trade-offs

- Large single-root containers can still be expensive if all child rows are materialized at once.
  - Mitigation: expose children through slices/pages and only format visible rows plus a small buffer.

- Curses bindings may differ across macOS/Linux environments.
  - Mitigation: isolate the backend in a small adapter module so input and rendering abstractions are easy to replace if one binding proves unreliable.

- Reloading a file that has changed on disk can invalidate the current path.
  - Mitigation: store path segments semantically and restore the deepest still-valid location after re-indexing; fall back to root if needed.

- External editor availability and cursor placement differ across environments.
  - Mitigation: prefer `$EDITOR`, fall back to `nvim`, and pass cursor positioning only for supported editor families while treating exact placement as best-effort for others.

- Type-ahead search can be ambiguous when labels and summaries share repeated prefixes.
  - Mitigation: define deterministic behavior as "jump to the first matching child in current source order" and reset the buffer after a short idle timeout.

- Inline span replacement can produce invalid Gene syntax if the replacement token is malformed.
  - Mitigation: validate edits as supported single-token scalar values before writing, keep the user in edit mode on validation failure, and allow cancel with `Esc`.

## Migration Plan

This change is additive. Existing commands keep their current behavior, and users opt into the viewer explicitly with `gene view`.

## Open Questions

- Whether the first version should depend directly on a specific Nim ncurses package or ship a minimal local wrapper over the system library.
  A: yes use the best ncurses package (or use the stdlib if it's available and good enough). This is a long term project and should build on a solid foundation.
