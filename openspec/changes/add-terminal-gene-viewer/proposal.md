## Why

Large Gene data files and append-only Gene logs are hard to inspect with the current CLI. Existing commands either print the entire structure as text or execute/compile the file, which is not practical for large nested documents where a user needs to browse incrementally.

## What Changes
- Add a new `gene view <file>` command that opens an interactive terminal viewer for Gene data files and multi-form Gene logs.
- Use a full-screen ncurses-backed interface with arrow-key navigation, a header that shows the file path and current logical path, and a footer that shows supported function keys.
- Add an `F2` edit action that temporarily leaves the viewer, opens the current file in an external terminal editor near the selected node, and reloads the viewer when the editor exits.
- Add direct type-ahead navigation so digit sequences jump to indexed children and text sequences jump to the first matching child label or summary.
- Add `Esc` to jump back to the root container and `Ctrl-E` as an edit shortcut alongside `F2`.
- Require a confirmation press for `Ctrl-C`, showing a hint after the first press and exiting on the second.
- Add inline editing for simple scalar values so the user can press `Tab` to edit a selected literal/token in place and `Enter` to save it back to the file, while using the same external-editor handoff as `F2` when `Tab` is pressed on non-scalar values.
- Make the viewer efficient for large inputs by indexing top-level entries incrementally and loading nested content only when the user drills into it.

## Impact
- Affected specs: `terminal-gene-viewer`
- Affected code: `src/gene.nim`, `src/commands/`, new viewer modules under `src/gene/`, parser integration in `src/gene/parser.nim`, `gene.nimble`, and new tests
