## Why
Gene historically split sum-type behavior across simple enums, built-in Result/Option shortcuts, and legacy Gene-expression ADT sketches. M002 unifies those surfaces so users have one public model for sum types and maintainers have one nominal identity path for declarations, checking, matching, imports, GIR cache artifacts, and serialization.

## What Changes
- **BREAKING**: Establish `enum` as the only public ADT declaration model; legacy Gene-expression ADT declarations are migration errors rather than an alternate supported syntax.
- Support generic enum declarations with colon parameters, such as `(enum Result:T:E ...)`, while preserving the canonical base enum name for type identity and runtime display.
- Record ordered metadata for unit and payload variants, including field names and optional field type descriptors.
- Enforce payload constructor arity, keyword construction rules, and annotated field types from the enum metadata.
- Back built-in `Result`, `Option`, and the `?` operator with ordinary enum identities and variants.
- Match enum values through `case` patterns, including qualified and unambiguous bare variants, declaration-order payload binding, unit variants, diagnostics, and exhaustiveness checks.
- Preserve nominal enum identity across imports, GIR cache artifacts, runtime serialization, and tree serialization/hash boundaries.
- Publish public specs, docs, runnable examples, and focused regression evidence for the completed enum ADT contract.
- Defer non-core refinements such as enum-specific methods, guards/or/as patterns, custom `?` protocols, optimizer specialization, broader non-enum pattern diagnostics, and any stable-core promotion decision.

## Impact
- Affected specs: `enum-adts`, `type-system`, `pattern-matching`
- Affected code: compiler enum declaration parsing, type checker enum registration and diagnostics, runtime enum metadata and constructors, built-in Result/Option initialization, `?` handling, enum `case` pattern resolution, GIR/module identity metadata, runtime and tree serialization, enum declaration tests, type-checker tests, GIR tests, testsuite fixtures, public specs, docs, and examples.
