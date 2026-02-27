## ADDED Requirements

### Requirement: Deterministic Package Root Precedence
For package-qualified imports, package root resolution SHALL follow fixed precedence: explicit path override, then lockfile, then materialized deps, then configured search paths.

#### Scenario: Lockfile wins over search-path fallback
- **WHEN** a package exists in both lockfile-resolved deps and generic search paths
- **THEN** the lockfile-resolved package root SHALL be selected

### Requirement: Package Boundary Confinement
After a package root is selected, module resolution for that package import SHALL stay within that package root's allowed module locations.

#### Scenario: Path escape rejected
- **WHEN** a package-qualified module import attempts to resolve outside the selected package root via traversal segments
- **THEN** resolution SHALL fail with a package-boundary diagnostic

### Requirement: Ambiguous Package Resolution Rejection
If multiple package roots are valid within the same precedence tier, package resolution SHALL fail explicitly instead of selecting arbitrarily.

#### Scenario: Multiple deps candidates
- **WHEN** package resolution finds more than one valid candidate in a single tier
- **THEN** the loader SHALL fail with an ambiguity diagnostic listing candidate roots

### Requirement: Structured Package Diagnostics
Package resolution failures SHALL provide stable error codes and package/import context.

#### Scenario: Package not found diagnostic payload
- **WHEN** a package-qualified import cannot resolve a package root
- **THEN** the diagnostic SHALL include stable error code, importer path, package name, and searched locations
