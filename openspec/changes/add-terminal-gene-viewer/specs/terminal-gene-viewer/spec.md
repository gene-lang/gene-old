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
- **AND** the initial version SHALL include `F1` for help, `F5` for reload, and `F10` for quit

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
