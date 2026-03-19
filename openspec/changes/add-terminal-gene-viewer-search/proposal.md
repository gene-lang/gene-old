## Why

The terminal Gene viewer currently supports only local type-ahead jumps within the current container. That is not enough for large nested files where the user needs to find a value anywhere in the document without manually drilling through intermediate levels.

## What Changes
- Add a dedicated whole-tree search mode to `gene view`, entered with `Ctrl-F`.
- Render the active search prompt on its own row above the body view so it does not conflict with inline scalar editing in the footer.
- Allow the user to edit the search query in place while search mode is active, keep the query live across result navigation, and exit search mode with `Esc`.
- Use `Ctrl-F` to execute forward search and repeat to the next match, and `Ctrl-Shift-F` to execute backward search through the same result set.
- Search across the entire document tree instead of the current container only, and navigate the viewer to the matched node when a result is activated.
- Define empty-query and no-match behavior so repeated search keys never leave the viewer in an ambiguous state.

## Impact
- Affected specs: `terminal-gene-viewer`
- Affected code: `src/gene/viewer/model.nim`, `src/gene/viewer/app.nim`, `src/gene/viewer/curses_backend.nim`, `src/commands/view.nim`, and viewer tests
