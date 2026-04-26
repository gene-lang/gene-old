# Type System MVP - Current Status

**Started:** 2026-01-29  
**Status:** Active, partially delivered  
**Language mode:** Gradual-first by default

For the target coherence contract, see [Gradual Typing Foundation](gradual-typing.md). That document defines the M006 foundation goal for descriptor metadata verification, source/GIR parity, diagnostics, and opt-in strict nil; this page remains the current-state delivered/missing split.

## What Is True Now

Gene already ships a real gradual typing pipeline:

- Compile-time checking runs by default with `strict = false`
- Missing annotations default to `Any`
- Runtime validation uses descriptor metadata (`TypeId` / `TypeDesc`)
- GIR persists typing metadata, including descriptor tables and type aliases
- Returns, locals, arguments, and typed properties are enforced at runtime when type checking is enabled
- Default nil compatibility is permissive today; strict nil is a future opt-in foundation target, not current default behavior

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

### Persistence
- Descriptor tables in GIR
- Scope tracker `type_expectation_ids`
- Matcher `type_id` and `return_type_id`
- `type_aliases`
- Module type metadata for import-time checking

## Still Missing

### P0
- One fully canonical descriptor pipeline across checker, compiler metadata, GIR, and runtime object materialization
- Broader negative-path coverage for mixed typed/untyped boundaries
- More complete flow typing beyond the common `if`/`case` guard patterns

### P1
- Better generic support beyond function/method type params
- Better diagnostics around generic mismatches and narrowing failures
- Better example and documentation coverage

### Deferred
- Generic classes
- Bounds / constraints (`^where`)
- Reified runtime generic class instances
- Full static-only mode as the primary language story

## Practical Guidance

- Use `Any` when you want dynamic opt-out
- Use explicit annotations on function boundaries and properties first
- Use `--no-type-check` to disable both compile-time and runtime enforcement
- Use `--no-gir-cache` when validating type-system changes from source

## References

- `docs/compiler.md`
- `docs/proposals/implemented/gradual-typing-architecture-review.md`
- `docs/how-types-work.md`
- `src/gene/type_checker.nim`
