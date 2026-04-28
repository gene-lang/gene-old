# Gradual Typing Foundation

This document is the canonical in-repo foundation contract for Gene's gradual typing coherence work. It is written for type-system implementers and reviewers who need to implement, review, or verify the descriptor verifier, GIR parity, strict nil, and final-gate surfaces without relying on downloaded research notes or historical proposal archaeology.

## Status

The M006 coherence foundation is implemented as a foundation, not as a claim that every gradual-typing feature is complete.

Current Gene has a gradual-first type pipeline: source is parsed, checked in non-strict mode, compiled with descriptor metadata, optionally saved to GIR, and executed with runtime validation when type checking is enabled. Existing typed boundaries include annotated function arguments, returns, locals, assignments, class properties, enum payloads, type aliases, runtime type values, and import/module metadata.

M006 adds the coherence layer around that existing pipeline:

- source compilation verifies descriptor metadata before successful output is accepted or serialized;
- GIR loading verifies descriptor metadata before loaded units are exposed to imports, execution, or runtime validation;
- source/GIR parity is proven by deterministic source and loaded descriptor metadata summaries plus typed-boundary behavior checks;
- default nil compatibility remains permissive for gradual programs; and
- `--strict-nil` is available as an opt-in scaffold for rejecting implicit `nil` at typed boundaries.

The feature remains Beta. This foundation makes metadata coherence testable and fail-closed; it does not deliver broad runtime guard unification, structured blame diagnostics, broad flow typing, native typed facts, generic classes, bounds, monomorphization, deep collection checks, wrappers, proxies, or a static-first language mode.

## Current Snapshot

Today, Gene's type system is descriptor-based and gradual by default:

- Missing annotations resolve to dynamic `Any` behavior.
- Compile-time checking runs in non-strict mode by default, so many issues are warnings rather than hard errors.
- Runtime validation uses `TypeId` references into `TypeDesc` tables for annotated boundaries.
- GIR persists descriptor tables, type aliases, scope type expectations, matcher metadata, and module type metadata.
- Cached GIR can affect observed behavior, so source-vs-cache checks matter when validating typing changes.
- Default nil compatibility is permissive: several typed runtime paths allow `nil` unless strict nil is explicitly enabled.

The foundation closes the descriptor metadata coherence gap for invalid metadata. A bad descriptor reference should fail at the source compile or GIR load boundary rather than silently degrading to `Any`. Valid gradual programs retain the permissive defaults that existed before the verifier work.

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

The public contract is owner-oriented: every invalid-metadata diagnostic must say which owner and nested path contained the bad reference.

## Source and GIR Boundaries

The source/GIR boundary is the critical coherence line.

### Source compilation verifier

After the type checker and compiler have produced or merged descriptor metadata, source compilation verifies the full owner graph before the output is accepted, executed, or serialized. A source program with invalid metadata fails during the source compile phase with an actionable `GENE_TYPE_METADATA_INVALID` diagnostic.

The implemented phase label is `source compile`.

### GIR loading verifier

After GIR metadata is read, the loader verifies descriptor tables, aliases, module metadata, matchers, scope snapshots, and nested descriptor references before the loaded unit can satisfy an import, execute, or feed runtime validation.

A corrupted or stale GIR artifact fails during the GIR load phase before any typed metadata is consumed. The implemented phase label is `GIR load`. The diagnostic path field identifies the loaded artifact so users and agents can rebuild or replace the cache rather than falling back to `Any`.

### Source/GIR parity proof

A program compiled from source and the same program loaded from current GIR must expose equivalent gradual typing metadata and runtime typed-boundary behavior.

M006 proves this with deterministic descriptor metadata summaries for the source-compiled unit and the loaded GIR unit. The parity tests compare descriptor tables, type aliases, module type metadata, and instruction-carried typed metadata, then report the first mismatched source/loaded summary line if they diverge. Invalid metadata discovered while preparing either side still fails through `GENE_TYPE_METADATA_INVALID` at the `source compile` or `GIR load` boundary.

The foundation does not require a separate runtime `source-gir-parity` diagnostic marker. A later milestone may add one if parity checking becomes a user-facing runtime boundary instead of a test-gate proof.

## Nil Modes

Gene remains gradual-first.

### Default nil compatibility

Default mode keeps existing nil-compatible behavior. Users are not forced to rewrite working gradual programs with explicit `Nil` unions because the descriptor verifier exists. If strict nil is not enabled, `nil` may continue to pass through typed boundaries that already allow it by default.

### Opt-in `--strict-nil`

Strict nil is an explicit opt-in mode for typed boundaries, enabled through the `--strict-nil` runtime flag on execution commands. When strict nil is enabled, `nil` is rejected for a typed argument, return, local assignment, or property assignment unless the expected type is one of:

- `Any`
- `Nil`
- `Option[T]`
- a union that contains `Nil`

Strict nil behaves the same whether the metadata came from source compilation or from GIR loading. Strict nil mismatches use `GENE_TYPE_MISMATCH` and include wording that the allowed targets are `Any, Nil, Option[T], or unions containing Nil`.

## Diagnostics

Invalid descriptor metadata produces `GENE_TYPE_METADATA_INVALID`.

Each invalid-metadata diagnostic includes enough structural context for a maintainer or agent to locate and fix the broken owner without re-running broad forensics:

- `phase`: currently `source compile`, `GIR load`, or a more specific compile subphase such as function or block body compilation.
- `owner/path`: the typed metadata owner and nested descriptor path.
- `invalid TypeId`: the concrete invalid ID.
- `descriptor-table length`: the table size used for validation.
- `source path`: the source path for source compilation, or the GIR artifact path when the GIR loader is validating a loaded unit.
- `detail`: the structural reason the reference is invalid.

For ordinary type mismatches at runtime, existing mismatch diagnostics remain separate. `GENE_TYPE_METADATA_INVALID` is specifically for incoherent descriptor metadata, corrupted GIR metadata, or invalid metadata discovered while preparing a source/GIR parity proof. Gate output should stay structural and avoid logging secrets, PII, full source payloads, large descriptor tables, or bytecode dumps.

## Verification Expectations

Foundation evidence should cover the implemented surfaces together:

1. Source compilation rejects invalid descriptor metadata before execution or GIR save.
2. GIR loading rejects corrupted descriptor metadata before import, execution, or runtime validation.
3. Source/GIR parity proves source-compiled and cached-GIR execution agree through deterministic descriptor metadata summary comparisons and typed-boundary behavior checks.
4. Default mode proves nil-compatible programs still work without strict nil.
5. Strict nil mode proves implicit `nil` rejection and explicit `Nil`, `Option[T]`, or union-with-`Nil` acceptance at typed boundaries.
6. Diagnostics prove `GENE_TYPE_METADATA_INVALID` includes phase, owner/path, invalid `TypeId`, descriptor-table length, path context, and structural detail.
7. Documentation and OpenSpec validation prove future agents can find this contract and distinguish implemented foundation behavior from Deferred work.

The final gate should fail if any of those surfaces are missing. It should not describe partial implementation as a complete gradual type system.

## Deferred Work

The foundation intentionally does not deliver every type-system feature. The following tracks remain Deferred unless a later approved change implements them:

- Structured blame diagnostics.
- Unified runtime guard APIs beyond the current descriptor validation paths.
- Broad flow typing expansion beyond currently supported patterns.
- Native typed-fact lowering.
- Generic classes.
- Bounds and constraints.
- Reified runtime generic class instances.
- Monomorphization or typed opcode specialization.
- Full static-only mode as the primary language story.
- Deep collection element enforcement for applied collection types.
- Wrapper or proxy semantics for typed boundaries.
- Public exposure of private checker bridge machinery as language semantics.

The foundation is about descriptor metadata coherence for gradual typing. It is not a promise that Gene has become a static-first language.

## Relationship to Existing Docs

Use the current type-system walkthrough for today's pipeline, commands, and practical cache notes. Use the type-system MVP status page for the current delivered/missing split. Use the feature-status matrix to understand that gradual typing remains Beta even with the M006 foundation in place.

Use this document for the M006 coherence contract: descriptor metadata invariants, source/GIR verification boundaries, default nil compatibility, opt-in strict nil semantics, required diagnostics, final gate expectations, and Deferred tracks.

Historical architecture-review material remains useful background, but it is not the authoritative contract for this foundation. The OpenSpec change and this document are the authoritative in-repo design surfaces for implementation and review.
