## ADDED Requirements

### Requirement: Formatter Command
The CLI SHALL provide a `gene fmt` command that formats Gene source files deterministically.

#### Scenario: Format file in place
- **WHEN** the user runs `gene fmt file.gene`
- **THEN** the file is rewritten with canonical formatting
- **AND** command exits with status code `0`

#### Scenario: Check mode reports non-canonical source
- **WHEN** the user runs `gene fmt --check file.gene` on a file that is not canonically formatted
- **THEN** the file content is not modified
- **AND** command exits with a non-zero status code

#### Scenario: Check mode accepts canonical source
- **WHEN** the user runs `gene fmt --check file.gene` on an already canonical file
- **THEN** the file content is not modified
- **AND** command exits with status code `0`

### Requirement: Canonical Formatting Rules
The formatter SHALL apply one canonical layout for equivalent parsed Gene forms.

#### Scenario: Indentation and spacing
- **WHEN** nested forms are formatted
- **THEN** indentation is exactly 2 spaces per nesting level
- **AND** spacing between adjacent elements is a single space

#### Scenario: Property ordering
- **WHEN** a form contains properties in `^key value` shape
- **THEN** properties are emitted in ascending alphabetical key order before non-property children

#### Scenario: Width-aware wrapping
- **WHEN** a form exceeds 100 characters in single-line layout
- **THEN** the formatter emits a deterministic multi-line layout that keeps semantic order unchanged

#### Scenario: Top-level separation
- **WHEN** a source file contains multiple top-level forms
- **THEN** each top-level form is separated by one blank line

### Requirement: Source Fidelity Constraints
The formatter SHALL preserve syntax content that must not be rewritten semantically.

#### Scenario: Preserve string literals
- **WHEN** a file contains string literals
- **THEN** their literal content is preserved exactly

#### Scenario: Preserve comments
- **WHEN** a file contains line or block comments
- **THEN** comments are preserved in deterministic output with relative placement anchored to surrounding forms

### Requirement: Deterministic Output
Formatter output SHALL be deterministic for the same parsed semantics and comments.

#### Scenario: Reformat stability
- **WHEN** `gene fmt` runs on already canonical output
- **THEN** the resulting content is byte-for-byte identical
