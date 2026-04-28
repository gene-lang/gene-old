## Reader and Post-Read Action

Reader: a Gene type-system implementer or reviewer who was not present for M006 planning.

Post-read action: implement, review, or verify the gradual typing foundation without relying on downloaded research notes or historical proposal archaeology.

## Context

Gene already has a gradual-first type pipeline: source is parsed, type checked in non-strict mode, compiled with descriptor metadata, optionally serialized to GIR, and executed with runtime boundary validation when type checking is enabled. The core metadata shape is descriptor-first: `TypeId` references index a `TypeDesc` table, and those references are attached to function matchers, scope trackers, class property metadata, runtime type values, compilation units, module type registries, and GIR payloads.

M006 turns that existing metadata shape into an enforceable coherence foundation. The implemented foundation verifies descriptor metadata at source compile and GIR load boundaries, proves source/GIR parity through deterministic source and loaded descriptor metadata summaries, and adds an opt-in strict nil scaffold while preserving default gradual nil compatibility.

## Goals

- Establish one canonical OpenSpec and documentation surface for the gradual typing foundation.
- Make descriptor metadata invalid states fail loudly before execution or import-time type use.
- Preserve default gradual typing compatibility, including existing nil-compatible behavior.
- Define opt-in strict nil semantics without making strict nil the default language mode.
- Give reviewers a final gate that proves source compile, cached GIR, nil modes, diagnostics, and documentation all agree.

## Non-Goals

- No historical OpenSpec proposals are edited or treated as current truth.
- No full static-only mode, generic class system, bounds/constraints, monomorphization, deep collection element enforcement, wrapper/proxy model, or public checker-bridge semantics is delivered by this foundation.
- No broad runtime guard unification, structured blame diagnostics, broad flow typing expansion, or native typed-fact lowering is delivered by this foundation.
- No new runtime `source-gir-parity` diagnostic marker is required for M006; parity remains a deterministic test-gate proof unless a later milestone promotes it to a user-facing runtime boundary.

## Foundation Contract

### Descriptor metadata invariant

Every typed metadata owner that stores a `TypeId` MUST either store `NO_TYPE_ID` for an intentionally untyped slot or store an ID that indexes the descriptor table visible to that owner. Compound descriptors MUST recursively obey the same rule for applied arguments, union members, function parameters, and function returns.

The important owners are:

- Function and block matcher parameter/return metadata.
- Scope tracker and scope snapshot type expectation metadata.
- Class and interface property metadata.
- Runtime type values and type aliases.
- Compilation-unit descriptor tables, module type registries, and module type trees.
- GIR-loaded compilation units and imported module metadata.

### Verification phases

Source verification runs after checker descriptors are merged into compiler output and before successful compilation output is accepted or saved. The implemented diagnostic phase label is `source compile`; compile subpaths may use more specific labels such as init, function body, or block body compilation.

GIR verification runs after GIR metadata is read and before the loaded unit is exposed to import, execution, or runtime validation. The implemented diagnostic phase label is `GIR load`.

Source/GIR parity is proven by deterministic descriptor metadata summaries generated from a source-compiled unit and the corresponding loaded GIR unit. The parity surface compares descriptor tables, type aliases, module type metadata, and instruction-carried typed metadata. When either side contains invalid metadata, it fails through the source compile or GIR load verifier. When summaries diverge, the parity test reports the fixture and first mismatched source/loaded summary line instead of requiring a separate runtime diagnostic marker.

Strict nil is opt-in. Default mode remains gradual-compatible. Strict nil rejects `nil` at typed boundaries unless the expected type is `Any`, `Nil`, `Option[T]`, or a union containing `Nil`.

### Diagnostic contract

Invalid metadata MUST produce `GENE_TYPE_METADATA_INVALID`. The message or structured diagnostic payload MUST include:

- `phase`: currently `source compile`, `GIR load`, or a more specific compile subphase.
- `owner/path`: the metadata owner and nested path to the bad reference.
- `invalid TypeId`: the concrete invalid ID.
- `descriptor-table length`: the table size used for validation.
- path context: the source path during source compilation or the GIR artifact path during GIR loading.
- structural detail explaining why the descriptor reference is invalid.

The verifier MUST NOT silently coerce invalid metadata to `Any`; silent fallback is the failure mode this foundation removes.

## Risks and Mitigations

- Risk: stricter metadata validation exposes old cache files or migration artifacts. Mitigation: fail before execution with path context so users can rebuild caches.
- Risk: strict nil could break existing gradual code. Mitigation: keep strict nil opt-in and preserve default nil-compatible behavior.
- Risk: diagnostics become too broad to act on. Mitigation: require phase, owner/path, invalid ID, table length, and path metadata in every invalid-metadata diagnostic.
- Risk: parity wording overpromises runtime behavior. Mitigation: keep source/GIR parity as deterministic source/loaded descriptor metadata summary evidence in M006 and defer richer user-facing parity diagnostics to a later milestone.

## Reader-Test Pass

A cold reader can identify what the M006 foundation implements, which diagnostics must be observable, how source/GIR parity is proven, how strict nil admits `Any`, `Nil`, `Option[T]`, and unions containing `Nil`, and which type-system tracks remain deferred. The design avoids relying on historical proposal files as the source of truth.
