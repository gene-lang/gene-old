## Context

The current terminal viewer already has two navigation styles:
- structural navigation with arrows, paging, and enter/left-right movement
- short-lived type-ahead that searches only within the current container

The requested search behavior is different. It needs a persistent query, a distinct search mode, and traversal across the whole document tree even when the match is buried inside unopened descendants.

## Goals / Non-Goals

- Goals:
  - Enter a dedicated search mode with `Ctrl-F`
  - Keep the search query editable on a dedicated prompt row above the body view
  - Search the whole tree rather than only the current container
  - Reuse repeated `Ctrl-F` presses to continue forward through matches
  - Support backward traversal with `Ctrl-Shift-F`
  - Move the viewer to the matched node and keep normal browsing available after each jump
- Non-Goals:
  - A separate results list or search sidebar
  - Regex syntax, boolean filters, or structural query language
  - Match highlighting for every hit in the tree at once
  - Replacing or editing through the search prompt

## Decisions

- Decision: add a dedicated search mode instead of extending the existing type-ahead buffer.
  - Rationale: whole-tree search needs a persistent query, explicit execution keys, and repeated next/previous navigation. The existing 0.5-second container-local buffer is the wrong interaction model.

- Decision: render the search prompt on its own row between the header chrome and the scrollable body.
  - Rationale: the footer is already used for function keys, status text, and inline scalar editing. A dedicated prompt row avoids collisions between search input and inline edit mode.
  - Consequence: the body viewport loses one row while search mode is active.

- Decision: make the search prompt an editable single-line buffer.
  - Supported prompt editing:
    - printable character insertion
    - `Backspace`
    - `Delete`
    - `Left` / `Right`
    - `Home` / `End`
  - Rationale: whole-tree search is only useful if the user can refine the query without leaving and re-entering search mode.

- Decision: define search scope as the full document tree in depth-first source order.
  - Rationale: users need predictable “first”, “next”, and “previous” semantics. Depth-first source order matches how the document is naturally browsed and how rows are derived today.
  - Consequence: a match may live outside the current open container, so activating it must rebuild the frame stack to the matched path.

- Decision: search against the same user-facing row text the viewer already renders.
  - Searchable text includes:
    - the node label shown in the current row
    - the node summary/value text shown in the current row
  - Rationale: this keeps search aligned with what the user can actually see when the node is selected.

- Decision: treat `Ctrl-F` as both “enter search mode” and “search next”.
  - Behavior:
    - first `Ctrl-F` enters search mode and focuses the prompt
    - `Ctrl-F` with a non-empty query and no active result executes the first forward search
    - `Ctrl-F` after the query text changes executes a fresh forward search for the updated query
    - repeated `Ctrl-F` without an intervening query edit advances to the next match
  - Rationale: this matches the requested workflow and keeps the control surface small.

- Decision: treat `Ctrl-Shift-F` as backward search over the active query.
  - Behavior:
    - with a non-empty query and no active result, it selects the last match in search order
    - `Ctrl-Shift-F` after the query text changes executes a fresh backward search for the updated query
    - with an active result and no intervening query edit, it selects the previous match
  - Rationale: reverse search should be symmetrical with forward search.
  - Consequence: terminal backends may not reliably distinguish `Ctrl-F` from `Ctrl-Shift-F`, so the key decoding layer must either detect a distinct reverse-search sequence or provide a terminal-specific fallback.

- Decision: keep search mode active after a match jump.
  - Rationale: the user explicitly wants repeated `Ctrl-F` presses to continue to the next hit. The prompt and query therefore stay active until canceled with `Esc`.

- Decision: `Esc` exits search mode and clears the active search session.
  - Rationale: `Esc` already acts as the viewer’s mode escape key. In search mode it should leave search first rather than jump to root.
  - Consequence: `Esc` becomes mode-sensitive in the same way it already is for inline edit cancel.

- Decision: empty-query execution is a no-op that stays in search mode.
  - Rationale: pressing `Ctrl-F` again before typing should not unexpectedly move selection or exit the prompt.

- Decision: no-match execution keeps the current selection unchanged and shows a status message.
  - Rationale: failing search should not disorient the user by moving them away from their current location.

- Decision: changing the query resets the active result position.
  - Rationale: once the user edits the search text, the next forward/backward execution should start a fresh traversal for the new query.

## Risks / Trade-offs

- Whole-tree search may force expansion/indexing of unopened subtrees.
  - Mitigation: traverse lazily and cache searchable row summaries as branches are visited during search.

- Search jumps can be disorienting when they move far away from the current location.
  - Mitigation: always update the header path to the matched node and preserve the current query in the search prompt so the user understands that the jump came from search.

- `Ctrl-Shift-F` is not portable across all terminals.
  - Mitigation: isolate reverse-search decoding in the curses backend and keep the model/UI contract independent of any one key sequence.

## Migration Plan

This change is additive. Existing arrow navigation, type-ahead, and inline edit behavior remain unchanged outside of the new search mode.
