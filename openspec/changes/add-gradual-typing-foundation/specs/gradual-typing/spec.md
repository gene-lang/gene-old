## ADDED Requirements

### Requirement: Canonical Foundation Documentation
The gradual typing foundation SHALL have a canonical in-repo design document and discoverability links that distinguish implemented M006 foundation behavior from deferred gradual-typing tracks.

#### Scenario: Foundation contract is discoverable from current docs
- **WHEN** a maintainer reads the current type-system walkthrough, type-system status page, documentation index, or feature-status matrix
- **THEN** the maintainer can navigate to the gradual typing foundation design without relying on downloaded research reports or historical proposal archaeology
- **AND** the maintainer can tell that the foundation is implemented while broader gradual-typing work remains Beta or Deferred

### Requirement: Descriptor Metadata Ownership
Every typed metadata owner SHALL reference descriptor metadata using `TypeId` values that are valid for that owner's descriptor table, or `NO_TYPE_ID` when the slot is intentionally untyped.

#### Scenario: Owner metadata references an in-range descriptor
- **WHEN** function matcher metadata, scope type expectations, class property metadata, runtime type values, type aliases, module metadata, or GIR-loaded metadata stores a non-`NO_TYPE_ID` value
- **THEN** that `TypeId` indexes the descriptor table visible to the owner
- **AND** nested applied, union, and function descriptors also reference valid descriptor IDs

### Requirement: Source Descriptor Metadata Verification
Source compilation SHALL verify descriptor metadata before successful output is accepted or serialized.

#### Scenario: Source verifier rejects an invalid TypeId
- **WHEN** source compilation produces typed metadata whose owner references an invalid `TypeId`
- **THEN** compilation fails before execution or GIR save with `GENE_TYPE_METADATA_INVALID`
- **AND** the diagnostic identifies phase `source compile`, owner/path, invalid `TypeId`, descriptor-table length, source path, and structural detail

### Requirement: GIR Descriptor Metadata Verification
GIR loading SHALL verify descriptor metadata before a loaded unit is exposed to import-time type checking, execution, or runtime validation.

#### Scenario: GIR verifier rejects corrupted descriptor metadata
- **WHEN** a GIR file contains a descriptor table or typed metadata owner with an out-of-range descriptor reference
- **THEN** loading fails before the unit can execute or satisfy an import
- **AND** the diagnostic identifies phase `GIR load`, owner/path, invalid `TypeId`, descriptor-table length, the loaded artifact path, and structural detail

### Requirement: Source and GIR Typing Parity
A program compiled from source and the same program loaded from current GIR SHALL expose equivalent gradual typing metadata and runtime boundary behavior.

#### Scenario: Source and GIR paths agree on descriptor metadata summaries
- **WHEN** a typed program is compiled from source and loaded from a current GIR cache artifact
- **THEN** deterministic source and loaded descriptor metadata summaries match for descriptor tables, type aliases, module type metadata, and instruction-carried typed metadata
- **AND** runtime typed-boundary behavior is equivalent for the source and loaded GIR paths
- **AND** invalid metadata encountered while preparing either side fails through `GENE_TYPE_METADATA_INVALID` with phase `source compile` or `GIR load`
- **AND** pure parity mismatches identify the fixture and first mismatched source/loaded descriptor metadata summary line without requiring a runtime `source-gir-parity` diagnostic marker

### Requirement: Default Nil Compatibility
Default gradual typing mode SHALL preserve existing nil-compatible behavior and SHALL NOT make strict nil checks mandatory.

#### Scenario: Existing nil-compatible programs keep working by default
- **WHEN** strict nil mode is not enabled
- **THEN** typed programs that currently rely on default nil compatibility continue to compile and run under the default gradual type-checking mode
- **AND** users are not required to rewrite those programs to include explicit `Nil` unions until they opt into strict nil

### Requirement: Opt-In Strict Nil
Strict nil behavior SHALL be available as an explicit opt-in `--strict-nil` runtime mode for typed boundaries.

#### Scenario: Strict nil rejects implicit nil at typed boundaries
- **WHEN** strict nil mode is enabled and a typed argument, return, local assignment, or property assignment receives `nil`
- **THEN** the runtime rejects `nil` unless the expected type is `Any`, `Nil`, `Option[T]`, or a union containing `Nil`
- **AND** the same behavior applies when the typed metadata came from source compilation or GIR loading

### Requirement: Final Foundation Gate
The gradual typing foundation SHALL have a final verification gate that proves the contract across source compilation, GIR loading, source/GIR parity, nil modes, diagnostics, and documentation links.

#### Scenario: Final gate proves foundation coherence
- **WHEN** the final foundation gate runs
- **THEN** it validates the OpenSpec change, source descriptor verifier, GIR descriptor verifier, source/GIR parity, default nil compatibility, strict nil mode, diagnostic metadata, and canonical documentation discoverability
- **AND** failures identify the missing foundation surface rather than claiming partial implementation as complete

### Requirement: Deferred Tracks Remain Explicit
The gradual typing foundation SHALL document non-core type-system tracks as deferred unless a later approved change implements them.

#### Scenario: Deferred work is not claimed by the foundation
- **WHEN** readers inspect the foundation design, tasks, or final evidence
- **THEN** structured blame diagnostics, broad runtime guard unification, broad flow typing expansion, native typed facts, generic classes, bounds/constraints, monomorphization, full static-only mode, deep collection element enforcement, wrappers, and proxies are clearly marked as deferred or out of scope
- **AND** the foundation does not expose private checker bridge machinery as public language semantics
