## ADDED Requirements

### Requirement: Interactive terminal viewer entry point
The CLI SHALL provide a `gene view <file>` command that opens an interactive terminal viewer for Gene data files.

#### Scenario: Open a Gene file in the viewer
- **GIVEN** a readable Gene data file at `logs/app.gene`
- **WHEN** the user runs `gene view logs/app.gene`
- **THEN** the command SHALL switch into a full-screen terminal viewer
- **AND** the initial screen SHALL show the opened file path
- **AND** the initial screen SHALL show the logical path of the currently selected node

### Requirement: Hierarchical arrow-key navigation
The viewer SHALL support arrow-key navigation for browsing nested Gene values.

#### Scenario: Move selection within the current container
- **GIVEN** the current node is a container with multiple visible children
- **WHEN** the user presses the Up or Down arrow key
- **THEN** the viewer SHALL move the current selection within that container
- **AND** keep the selected row visible in the scroll window

#### Scenario: Move by page within the current container
- **GIVEN** the current node is a container with more visible children than fit in one viewport
- **WHEN** the user presses Page Up or Page Down
- **THEN** the viewer SHALL move the current selection by approximately one viewport
- **AND** keep the selected row visible in the scroll window

#### Scenario: Drill into and back out of nested data
- **GIVEN** the current selection refers to a composite value such as an array, map, or Gene node
- **WHEN** the user presses the Right arrow key or Enter
- **THEN** the viewer SHALL enter that value and make it the current container
- **AND** update the logical path shown at the top of the screen
- **WHEN** the user presses the Left arrow key
- **THEN** the viewer SHALL return to the parent container
- **AND** restore the prior parent selection

#### Scenario: Jump directly back to the root container
- **GIVEN** the viewer is currently focused inside a nested container
- **WHEN** the user presses `Esc`
- **THEN** the viewer SHALL return to the root container
- **AND** preserve the current root-level selection

### Requirement: Type-ahead navigation jumps within the current container
The viewer SHALL support direct type-ahead navigation without entering a separate search mode.

#### Scenario: Numeric typing jumps to an indexed child
- **GIVEN** the current container has children with numeric indices such as array items, sequence items, or positional Gene children
- **WHEN** the user types one or more digits that form a non-negative integer
- **THEN** the viewer SHALL treat the buffered digits as an index query
- **AND** number indexed children starting at `1` for display and navigation
- **AND** move the selection to the first child whose displayed logical index equals that integer

#### Scenario: Text typing jumps to the first matching child
- **GIVEN** the current container has visible children with labels or summaries
- **WHEN** the user types printable characters and the buffered text is not parseable as a non-negative integer
- **THEN** the viewer SHALL move the selection to the first child in source order whose label or summary contains that buffered text

#### Scenario: Type-ahead buffer expires after a short idle interval
- **GIVEN** the user has already typed a partial type-ahead query
- **WHEN** more than 0.5 seconds elapse before the next printable keypress
- **THEN** the prior buffered query SHALL be discarded
- **AND** the next printable keypress SHALL start a new type-ahead query

#### Scenario: Type-ahead buffer extends within the timeout window
- **GIVEN** the user has already typed a partial type-ahead query
- **WHEN** another printable keypress arrives within 0.5 seconds
- **THEN** the viewer SHALL append that keypress to the existing query buffer
- **AND** apply navigation using the combined query string

### Requirement: Multi-form log files behave as a browsable root sequence
The viewer SHALL support append-only Gene logs and other files that contain multiple top-level forms.

#### Scenario: Browse a multi-form Gene log
- **GIVEN** a file that contains multiple top-level Gene values in source order
- **WHEN** the user opens that file with `gene view`
- **THEN** the viewer SHALL expose those values as a synthetic root sequence
- **AND** preserve their source order during navigation
- **AND** allow the user to enter an individual record with the Right arrow key

### Requirement: Large files are loaded lazily
The viewer SHALL avoid recursive eager parsing of unopened descendants when opening large files.

#### Scenario: Open a large file without materializing every nested node
- **GIVEN** a large Gene file with deeply nested records
- **WHEN** the user opens it in the viewer
- **THEN** the viewer SHALL index the top-level structure needed for the initial screen
- **AND** SHALL NOT recursively materialize every unopened descendant before first paint

#### Scenario: Expand nested data on demand
- **GIVEN** a large Gene file that has unopened nested containers
- **WHEN** the user drills into one of those containers
- **THEN** the viewer SHALL load or derive the child rows for that container on demand
- **AND** MAY cache the expanded result for later navigation in the same session

### Requirement: Viewer chrome shows path and session controls
The viewer SHALL provide persistent header and footer chrome for navigation context and session actions.

#### Scenario: Header shows current location
- **WHEN** the viewer is active
- **THEN** the top of the screen SHALL show the source file path
- **AND** SHALL show the logical path of the current node using path segments such as indices or keys

#### Scenario: Footer shows function-key actions
- **WHEN** the viewer is active
- **THEN** the bottom of the screen SHALL show supported function keys
- **AND** the initial version SHALL include `Esc` for root, `F1` for help, `F2` for edit, `F5` for reload, and `F10` for quit

### Requirement: Viewer can hand off editing to an external terminal editor
The viewer SHALL allow the user to open the current file in an external terminal editor and return to browsing afterward.

#### Scenario: Open the current selection in an editor
- **GIVEN** the viewer is active on a readable file
- **AND** an editor is available through `$EDITOR` or a default `nvim` fallback
- **WHEN** the user presses `F2` or `Ctrl-E`
- **THEN** the viewer SHALL restore the terminal before launching the editor
- **AND** SHALL open the same file at or near the currently selected node's source location
- **WHEN** the editor exits
- **THEN** the viewer SHALL reopen its terminal UI
- **AND** reload the file from disk
- **AND** restore the deepest still-valid logical path

#### Scenario: No external editor is available
- **GIVEN** the viewer is active
- **AND** no usable external editor command is configured or installed
- **WHEN** the user presses `F2` or `Ctrl-E`
- **THEN** the viewer SHALL remain available after the failed handoff
- **AND** show a clear status message describing the editor launch failure

### Requirement: Viewer reload and startup failures are recoverable
The viewer SHALL fail clearly when startup cannot proceed and SHALL allow a running session to reload the file from disk.

#### Scenario: File cannot be opened at startup
- **WHEN** the user runs `gene view missing.gene`
- **THEN** the command SHALL exit with a non-zero status
- **AND** print a clear error message that the file could not be opened

#### Scenario: Reload after file contents change
- **GIVEN** the viewer is open on a file that has changed on disk
- **WHEN** the user presses `F5`
- **THEN** the viewer SHALL rebuild its document view from the current file contents
- **AND** restore the deepest valid logical path it can
- **AND** fall back to the root view if the previous path no longer exists

#### Scenario: Ctrl-C requires confirmation before exiting
- **GIVEN** the viewer is active
- **WHEN** the user presses `Ctrl-C` once
- **THEN** the viewer SHALL remain active
- **AND** show a hint that `Ctrl-C` must be pressed again to exit
- **WHEN** the user presses `Ctrl-C` again without another intervening navigation action
- **THEN** the viewer SHALL exit
