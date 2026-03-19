## 1. Viewer State
- [x] 1.1 Add dedicated search-mode state, query buffer state, and active-match state to the non-TTY viewer model.
- [x] 1.2 Implement whole-tree traversal in depth-first source order and map matches back to logical paths that can be selected in the viewer.
- [x] 1.3 Reset active search position whenever the query text changes, while preserving the current query until the user exits search mode.
- [x] 1.4 Support single-line search prompt editing, including cursor movement and deletion operations.

## 2. Terminal UI
- [x] 2.1 Add keyboard handling for entering forward search with `Ctrl-F`, executing repeated forward search with `Ctrl-F`, and executing backward search with `Ctrl-Shift-F`.
- [x] 2.2 Render the live search prompt and cursor on a dedicated row above the body while search mode is active.
- [x] 2.3 Make `Esc` exit search mode before applying its normal browse-mode root-jump behavior.
- [x] 2.4 Show clear status feedback for empty-query execution and no-match searches without moving the current selection.

## 3. Validation
- [x] 3.1 Add model-level tests for whole-tree forward search, backward search, empty-query behavior, no-match behavior, and query reset after editing.
- [x] 3.2 Add tests for search prompt editing behavior, including insertion, deletion, and cursor movement.
- [x] 3.3 Add backend or app-level tests for `Ctrl-F` / reverse-search key handling and search-mode exit behavior.
- [x] 3.4 Update CLI/viewer help text to document the new search controls.
- [x] 3.5 Run `openspec validate add-terminal-gene-viewer-search --strict`.
