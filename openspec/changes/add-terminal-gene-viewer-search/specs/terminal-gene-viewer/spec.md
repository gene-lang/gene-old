## ADDED Requirements

### Requirement: Viewer SHALL provide dedicated whole-tree search mode
The terminal viewer SHALL provide a persistent search mode that traverses the entire document tree instead of searching only within the current container.

#### Scenario: Enter search mode with Ctrl-F
- **GIVEN** the viewer is active in normal browse mode
- **WHEN** the user presses `Ctrl-F`
- **THEN** the viewer SHALL enter search mode
- **AND** place the input cursor in a search prompt on a dedicated row above the body view
- **AND** preserve the current selection until the user executes a search

#### Scenario: Edit the active search query
- **GIVEN** the viewer is in search mode
- **WHEN** the user types printable characters or uses `Backspace`, `Delete`, `Left`, `Right`, `Home`, or `End`
- **THEN** the viewer SHALL update the search prompt contents or cursor position accordingly
- **AND** SHALL keep the current selection unchanged while the user is only editing the query

#### Scenario: Exit search mode with Esc
- **GIVEN** the viewer is in search mode
- **WHEN** the user presses `Esc`
- **THEN** the viewer SHALL leave search mode
- **AND** clear the active search session
- **AND** return to normal browse-mode key handling without changing the current selection

### Requirement: Viewer SHALL search the whole tree in stable order
The terminal viewer SHALL search all nodes in the opened document using a stable depth-first source order.

#### Scenario: Search finds a nested node outside the current container
- **GIVEN** the current selection is inside one branch of the document
- **AND** a search match exists in another unopened branch
- **WHEN** the user executes a search for that query
- **THEN** the viewer SHALL search beyond the current container into the rest of the document tree
- **AND** navigate to the matched node
- **AND** update the header path to the matched location

#### Scenario: First forward search stops at the first matching entry
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** no search result is currently active
- **WHEN** the user presses `Ctrl-F`
- **THEN** the viewer SHALL search the whole tree in depth-first source order
- **AND** stop at the first entry whose displayed label or summary contains the query text

#### Scenario: Repeated forward search advances to the next match
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** a matching entry is currently active
- **AND** the query has not changed since that match was selected
- **WHEN** the user presses `Ctrl-F` again
- **THEN** the viewer SHALL jump to the next matching entry in the same search order

#### Scenario: Backward search selects the previous match
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** a matching entry is currently active
- **AND** the query has not changed since that match was selected
- **WHEN** the user presses `Ctrl-Shift-F`
- **THEN** the viewer SHALL jump to the previous matching entry in the same search order

#### Scenario: Initial backward search starts from the end
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** no search result is currently active
- **WHEN** the user presses `Ctrl-Shift-F`
- **THEN** the viewer SHALL select the last matching entry in the same search order

#### Scenario: Forward search restarts after query edit
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** the query text has changed since the last active match was selected
- **WHEN** the user presses `Ctrl-F`
- **THEN** the viewer SHALL start a fresh forward traversal for the updated query
- **AND** stop at the first matching entry

#### Scenario: Backward search restarts after query edit
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** the query text has changed since the last active match was selected
- **WHEN** the user presses `Ctrl-Shift-F`
- **THEN** the viewer SHALL start a fresh backward traversal for the updated query
- **AND** stop at the last matching entry

### Requirement: Viewer SHALL handle empty and failed searches predictably
The terminal viewer SHALL keep search mode stable when the query is empty or when no match exists.

#### Scenario: Execute search with an empty query
- **GIVEN** the viewer is in search mode
- **AND** the query buffer is empty
- **WHEN** the user presses `Ctrl-F`
- **THEN** the viewer SHALL remain in search mode
- **AND** SHALL NOT change the current selection

#### Scenario: Execute backward search with an empty query
- **GIVEN** the viewer is in search mode
- **AND** the query buffer is empty
- **WHEN** the user presses `Ctrl-Shift-F`
- **THEN** the viewer SHALL remain in search mode
- **AND** SHALL NOT change the current selection

#### Scenario: Search query has no matches
- **GIVEN** the viewer is in search mode with a non-empty query
- **AND** no entry in the document matches that query
- **WHEN** the user executes forward or backward search
- **THEN** the viewer SHALL remain in search mode
- **AND** SHALL keep the current selection unchanged
- **AND** show a clear no-match status message

#### Scenario: Editing the query resets the active match position
- **GIVEN** the viewer is in search mode with an active search result
- **WHEN** the user edits the query text
- **THEN** the viewer SHALL clear the active match position for the prior query
- **AND** the next search execution SHALL start a fresh traversal for the updated query
