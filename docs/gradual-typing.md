# Gradual Typing Foundation

This document is the canonical in-repo foundation contract for Gene's gradual typing coherence work. It is written for type-system implementers and reviewers who need to implement or review the verifier, GIR parity, strict nil, and final-gate slices without relying on downloaded research notes or historical proposal archaeology.

## Status

This is a target foundation contract, not a claim that every behavior below is already implemented.

Current Gene already has a gradual-first type pipeline: source is parsed, checked in non-strict mode, compiled with descriptor metadata, optionally saved to GIR, and executed with runtime validation when type checking is enabled. Existing typed boundaries include annotated function arguments, returns, locals, assignments, class properties, enum payloads, type aliases, runtime type values, and import/module metadata.

The M006 foundation work tightens coherence across those surfaces. Until the downstream slices land, do not claim that the source descriptor verifier, GIR descriptor verifier, source/GIR parity gate, or strict nil mode exists as shipped runtime behavior.

## Current Snapshot

Today, Gene's type system is descriptor-based and gradual by default:

- Missing annotations resolve to dynamic `Any` behavior.
- Compile-time checking runs in non-strict mode by default, so many issues are warnings rather than hard errors.
- Runtime validation uses `TypeId` references into `TypeDesc` tables for annotated boundaries.
- GIR persists descriptor tables, type aliases, scope type expectations, matcher metadata, and module type metadata.
- Cached GIR can affect observed behavior, so source-vs-cache checks matter when validating typing changes.
- Default nil compatibility is permissive: several typed runtime paths allow `nil` to pass rather than requiring explicit `Nil` unions.

The current gap is not the absence of descriptor metadata. The gap is coherence: an invalid descriptor reference can still degrade to `Any` in some paths, and loaded GIR metadata is not yet protected by the same explicit invalid-metadata contract as source compilation. The foundation removes silent fallback for invalid metadata while preserving gradual compatibility for valid programs.

## Foundation Invariant

Every typed metadata owner that stores a `TypeId` must obey one rule:

- `NO_TYPE_ID` means the slot is intentionally untyped.
- Any other `TypeId` must index the descriptor table visible to that owner.

The invariant is recursive. Applied type arguments, union members, function parameter descriptors, and function return descriptors must also reference valid descriptor IDs in the same owner-visible table.

Invalid descriptor metadata must never be silently coerced to `Any`. Silent fallback is allowed only for intentionally untyped slots or for explicitly documented gradual behavior, not for corrupted or incoherent metadata.

## Metadata Owners

The foundation applies to every surface that carries typed metadata, including:

- Function, method, and block matcher parameter metadata.
- Function, method, and block return metadata.
- Scope trackers and scope snapshots that store local type expectations.
- Instructions or runtime paths that carry typed local or assignment expectations.
- Class and interface property metadata.
- Enum payload field metadata.
- Runtime type values and type aliases.
- Compilation-unit descriptor tables.
- Module type registries and module type trees.
- GIR-loaded compilation units and imported module metadata.

A future verifier may implement this with shared traversal helpers, but the public contract is owner-oriented: every diagnostic must say which owner and nested path contained the bad reference.

## Source and GIR Boundaries

The source/GIR boundary is the critical coherence line.

### Source compilation target

After the type checker and compiler have produced or merged descriptor metadata, source compilation should verify the full owner graph before the output is accepted, executed, or serialized. A source program with invalid metadata should fail during the source-compile phase with an actionable diagnostic.

This source verifier is target behavior for downstream work. It is not implemented by this document.

### GIR loading target

After GIR metadata is read, the loader should verify descriptor tables, aliases, module metadata, matchers, scope snapshots, and nested descriptor references before the loaded unit can satisfy an import, execute, or feed runtime validation.

A corrupted or stale GIR artifact should fail during the gir-load phase before any typed metadata is consumed. The error should point users toward rebuilding or replacing the cache rather than falling back to `Any`.

This GIR verifier is target behavior for downstream work. It is not implemented by this document.

### Source/GIR parity target

A program compiled from source and the same program loaded from current GIR should expose equivalent gradual typing metadata and runtime typed-boundary behavior. The parity check should compare descriptor metadata, type aliases, module type metadata, and runtime results for typed boundaries.

A source/GIR parity failure should report the mismatched owner/path and both source and GIR locations when they are known.

## Nil Modes

Gene remains gradual-first.

### Default nil compatibility

Default mode keeps existing nil-compatible behavior. Users should not be forced to rewrite working gradual programs with explicit `Nil` unions just because the descriptor verifier exists. If strict nil is not enabled, the foundation should preserve the current posture: `nil` may continue to pass through typed boundaries that already allow it by default.

### Opt-in strict nil target

Strict nil is an explicit opt-in target mode for typed boundaries. When strict nil is enabled, `nil` should be rejected for a typed argument, return, local assignment, or property assignment unless the expected type is one of:

- `Any`
- `Nil`
- a union that contains `Nil`

Strict nil must behave the same whether the metadata came from source compilation or from GIR loading. This document only defines the target semantics; it does not claim strict nil has already been implemented.

## Diagnostics

Invalid metadata must produce `GENE_TYPE_METADATA_INVALID`.

Each diagnostic should include enough context for a maintainer or agent to locate and fix the broken owner without re-running broad forensics:

- `phase`: `source-compile`, `gir-load`, or `source-gir-parity`.
- `owner/path`: the typed metadata owner and nested descriptor path.
- `invalid TypeId`: the concrete invalid ID.
- `descriptor-table length`: the table size used for validation.
- `source path`: the source location when known.
- `GIR path`: the GIR location when known or when parity is being checked.

For ordinary type mismatches at runtime, existing mismatch diagnostics remain separate. `GENE_TYPE_METADATA_INVALID` is specifically for incoherent descriptor metadata, corrupted GIR metadata, or source/GIR metadata mismatch.

## Verification Expectations

Foundation evidence should be accumulated in slices, not asserted early:

1. Source compilation rejects invalid descriptor metadata before execution or GIR save.
2. GIR loading rejects corrupted descriptor metadata before import, execution, or runtime validation.
3. Source/GIR parity proves source-compiled and cached-GIR execution agree on typed metadata and typed boundary behavior.
4. Default mode proves nil-compatible programs still work without strict nil.
5. Strict nil mode proves implicit `nil` rejection and explicit `Nil` acceptance at typed boundaries.
6. Diagnostics prove `GENE_TYPE_METADATA_INVALID` includes phase, owner/path, invalid `TypeId`, descriptor-table length, and source/GIR paths.
7. Documentation and OpenSpec validation prove future agents can find this contract and distinguish current behavior from target behavior.

The final gate should fail if any of those surfaces are missing. It should not describe partial implementation as complete.

## Deferred Work

The foundation intentionally does not deliver every type-system feature. The following tracks remain Deferred unless a later approved change implements them:

- Generic classes.
- Bounds and constraints.
- Reified runtime generic class instances.
- Monomorphization or typed opcode specialization.
- Full static-only mode as the primary language story.
- Broad flow typing expansion beyond currently supported patterns.
- Deep collection element enforcement for applied collection types.
- Public exposure of private checker bridge machinery as language semantics.

The foundation is about metadata coherence for gradual typing. It is not a promise that Gene has become a static-first language.

## Relationship to Existing Docs

Use the current type-system walkthrough for today's pipeline, commands, and practical cache notes. Use the type-system MVP status page for the current delivered/missing split. Use the feature-status matrix to understand that gradual typing remains Beta while this foundation is being implemented.

Use this document for the target M006 coherence contract: descriptor metadata invariants, source/GIR verification boundaries, default nil compatibility, opt-in strict nil target semantics, required diagnostics, final gate expectations, and Deferred tracks.

Historical architecture-review material remains useful background, but it is not the authoritative contract for this foundation. The OpenSpec change and this document are the authoritative in-repo design surfaces for downstream implementation and review.
