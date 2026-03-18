## 1. CLI Surface
- [x] 1.1 Add a `view` command module and register it in the main CLI help/dispatch path.
- [x] 1.2 Define startup/help/error behavior for `gene view <file>` including missing-file and invalid-input cases.
- [x] 1.3 Add any required ncurses dependency or build linkage needed by the terminal backend.

## 2. Viewer Data Model
- [x] 2.1 Implement a document model that can represent either a single root value or a synthetic root sequence for multi-form logs.
- [x] 2.2 Reuse parser streaming to index top-level entries without recursively loading unopened descendants.
- [x] 2.3 Implement lazy child expansion and a path model that preserves array indices, map keys, and Gene child/property navigation.
- [x] 2.4 Classify scalar nodes by editable token kind so inline editing can distinguish supported literals/tokens from non-editable nodes.

## 3. Terminal UI
- [x] 3.1 Implement the full-screen layout with header, scrollable body, and footer legend.
- [x] 3.2 Implement keyboard handling for Up, Down, Left, Right, `Esc`, `F1`, `F2`, `Ctrl-E`, `F5`, and `F10`.
- [x] 3.3 Render concise row summaries for scalar values and composite containers, including current selection highlighting.
- [x] 3.4 Implement external-editor handoff that reopens the file near the selected node and reloads the viewer on return.
- [x] 3.5 Implement a short-lived type-ahead buffer that accumulates printable keypresses and resets after 0.5 seconds of inactivity.
- [x] 3.6 Use numeric buffers to jump to indexed children and textual buffers to jump to the first matching child row in the current container.
- [x] 3.7 Require `Ctrl-C` confirmation in the viewer, showing a hint on the first press and exiting on the second.
- [x] 3.8 Add an inline edit mode entered with `Tab` for supported scalar values, with buffer editing in the TUI.
- [x] 3.9 Save valid inline edits on `Enter` by rewriting the selected source span, reloading the file, and restoring selection.
- [x] 3.10 Cancel inline edit mode on `Esc` without writing the file and fall back to the external editor when `Tab` is pressed on unsupported nodes.

## 4. Validation
- [x] 4.1 Add tests for top-level streaming/index behavior on multi-form Gene logs.
- [x] 4.2 Add tests for navigation/path behavior in the non-TTY viewer state machine.
- [x] 4.3 Add tests for editor target location and editor command shaping.
- [x] 4.4 Add a CLI-level regression test for command startup/help/error handling.
- [x] 4.5 Run `openspec validate add-terminal-gene-viewer --strict`.
- [x] 4.6 Add tests for numeric and textual type-ahead navigation, including timeout-based buffer reset behavior.
- [x] 4.7 Add tests for supported/unsupported inline edit entry, save success, validation failure, and cancel behavior.
