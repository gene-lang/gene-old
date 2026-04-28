# Type System MVP - Current Status

**Started:** 2026-01-29  
**Status:** Active, partially delivered  
**Language mode:** Gradual-first by default

For the coherence contract, see [Gradual Typing Foundation](gradual-typing.md). That document defines the implemented M006 foundation for descriptor metadata verification, source/GIR parity proof, diagnostics, default nil compatibility, opt-in strict nil, and deferred tracks. This page remains the current-state delivered/missing split for the broader type system.

## What Is True Now

Gene already ships a real gradual typing pipeline:

- Compile-time checking runs by default with `strict = false`
- Missing annotations default to `Any`
- Runtime validation uses descriptor metadata (`TypeId` / `TypeDesc`)
- GIR persists typing metadata, including descriptor tables and type aliases
- Returns, locals, arguments, and typed properties are enforced at runtime when type checking is enabled
- Source compilation and GIR loading now verify descriptor metadata fail-closed instead of silently accepting invalid `TypeId` references
- Source/GIR parity is covered by deterministic source and loaded descriptor metadata summary tests for typed fixtures
- Default nil compatibility remains permissive today; `--strict-nil` is an opt-in scaffold that rejects implicit `nil` unless the expected type is `Any`, `Nil`, `Option[T]`, or a union containing `Nil`

## Delivered

### Compile-time
- `TypeExpr` inference and unification in `src/gene/type_checker.nim`
- Named, applied, union, function, and type-variable expressions
- Class, method, constructor, ADT, and import/module typing
- Flow-sensitive narrowing for common `if` and `case` patterns
- Explicit generic functions and methods via definition-name syntax such as `identity:T`

### Runtime
- Descriptor-backed validation in `src/gene/types/runtime_types.nim`
- Argument validation in `src/gene/vm/args.nim`
- Local/assignment validation in `src/gene/vm/exec.nim`
- Return-value validation in `src/gene/vm/core_helpers.nim`
- Typed property validation for class fields
- Opt-in strict nil diagnostics through `GENE_TYPE_MISMATCH`

### Persistence
- Descriptor tables in GIR
- Scope tracker `type_expectation_ids`
- Matcher `type_id` and `return_type_id`
- `type_aliases`
- Module type metadata for import-time checking

### Coherence Foundation
- Source compile descriptor metadata verification with `GENE_TYPE_METADATA_INVALID`
- GIR load descriptor metadata verification with `GENE_TYPE_METADATA_INVALID`
- Deterministic source/GIR descriptor metadata summary parity checks
- Default nil compatibility coverage
- Strict nil rejection and explicit nil-capable acceptance coverage

## Still Missing

### P0
- Broader negative-path coverage outside the M006 descriptor verifier and strict-nil scaffold
- More complete flow typing beyond the common `if`/`case` guard patterns
- Clearer user-facing diagnostics around complex generic mismatches and narrowing failures

### P1
- Better generic support beyond function/method type params
- Better example and documentation coverage for practical typed programs
- More complete type inference for mixed typed/untyped code

### Deferred
- Structured blame diagnostics
- Broad runtime guard unification
- Native typed facts
- Generic classes
- Bounds / constraints (`^where`)
- Reified runtime generic class instances
- Monomorphization or typed opcode specialization
- Deep collection element enforcement
- Wrappers/proxies for typed boundaries
- Full static-only mode as the primary language story

## Practical Guidance

- Use `Any` when you want dynamic opt-out
- Use explicit annotations on function boundaries and properties first
- Use `--no-type-check` to disable both compile-time and runtime enforcement
- Use `--no-gir-cache` when validating type-system changes from source
- Use `--strict-nil` only when you want implicit `nil` rejected at typed boundaries

## References

- `docs/gradual-typing.md`
- `docs/compiler.md`
- `docs/proposals/implemented/gradual-typing-architecture-review.md`
- `docs/how-types-work.md`
- `src/gene/type_checker.nim`
