## ADDED Requirements

### Requirement: Deterministic Module Resolution Contract
The module loader SHALL resolve module specifiers using a fixed precedence order and SHALL produce deterministic results for the same importer/specifier inputs.

#### Scenario: Relative path precedence
- **WHEN** a module import matches both an importer-relative file and a workspace fallback candidate
- **THEN** the importer-relative candidate SHALL be selected
- **AND** workspace fallback SHALL NOT override it

#### Scenario: Stable repeated resolution
- **WHEN** the same importer module resolves the same module specifier multiple times in one process
- **THEN** the loader SHALL produce the same canonical resolved path each time

### Requirement: Canonical Module Identity
The runtime SHALL canonicalize resolved module paths before cache lookup and cycle tracking so that one module file has one identity.

#### Scenario: Equivalent path spellings map to one module identity
- **WHEN** the same file is imported via path spellings that differ only by relative segments or absolute-vs-relative form
- **THEN** the module SHALL be loaded/executed once and reused from the same cache identity

### Requirement: Export Surface Enforcement
When a module declares explicit exports, imports SHALL be restricted to that export surface.

#### Scenario: Named import of non-exported symbol
- **WHEN** module `A` declares explicit exports and module `B` imports a symbol not in `A`'s export set
- **THEN** the import SHALL fail with an export-missing diagnostic

#### Scenario: Wildcard import honors explicit exports
- **WHEN** a wildcard import targets a module with explicit exports
- **THEN** only exported symbols SHALL be imported
- **AND** internal loader keys SHALL NOT be imported

### Requirement: Deterministic Cyclic Import Diagnostics
Cyclic imports SHALL fail deterministically with the complete cycle chain.

#### Scenario: Cycle chain surfaced
- **WHEN** module imports form a cycle
- **THEN** the runtime SHALL fail with a cycle diagnostic including the full ordered chain

### Requirement: Structured Module Diagnostics
Module-resolution failures SHALL include stable machine-readable codes and context.

#### Scenario: Module not found diagnostic payload
- **WHEN** module resolution fails because no candidate exists
- **THEN** the diagnostic SHALL include a stable error code, importer path, requested specifier, and searched roots/candidates
