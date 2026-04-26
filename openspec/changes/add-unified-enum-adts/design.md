## Context
Gene had runtime enum values, built-in Result/Option shortcuts, and a separate historical ADT story. The unified model makes `enum` metadata the source of truth for simple enums, payload-bearing sum types, built-in Result/Option values, pattern matching, and persistence identity.

This design note exists because the completed contract crosses compiler parsing, type checking, runtime metadata, built-in control flow, pattern matching, GIR/module metadata, and serialization.

## Goals / Non-Goals
- Goals:
  - Make `enum` the canonical public ADT declaration form.
  - Support generic enum heads such as `Result:T:E` while storing the base enum name.
  - Store ordered payload field names and optional type descriptors once, on enum member metadata.
  - Use that metadata for constructor arity, keyword construction, typed payload validation, field access, and pattern payload binding.
  - Back built-in `Result`, `Option`, and `?` with ordinary enum identities.
  - Preserve nominal enum identity across imports, GIR cache artifacts, runtime serialization, and tree serialization/hash boundaries.
  - Provide targeted diagnostics for malformed declarations, legacy ADT migration cases, constructor errors, enum pattern errors, and malformed serialized enum records.
- Non-Goals:
  - Add enum-specific methods or protocols.
  - Add guard, or, or as pattern forms.
  - Generalize `?` to custom user protocols.
  - Specialize optimizer paths for enum payloads.
  - Promote enum ADTs from Beta to stable core in this change.

## Decisions
- Decision: `enum` is the only public ADT declaration model.
  - Rationale: Keeping both runtime enums and Gene-expression ADTs would preserve the split this change removes.
  - Consequence: Docs and specs must not present `(type (Result T E) ...)` as an alternate supported ADT declaration.

- Decision: generic enum declaration parameters use colon syntax on the enum head.
  - Example: `(enum Result:T:E (Ok value: T) (Err error: E))`.
  - Rationale: This matches Gene's existing generic definition style and keeps type usage separate as `(Result Int String)`.

- Decision: canonical enum identity starts from the base declaration name and remains nominal.
  - Example: `Result:T:E` declares `Result` for runtime type names, type-checker lookup, GIR/module enum metadata, and serialization identity.
  - Rationale: Identity and persistence need a stable declaration identity rather than a syntax-bearing head string or display string.

- Decision: enum member metadata owns payload field descriptors.
  - Ordered field names and optional field type descriptors are stored on each enum member.
  - Rationale: Constructors, field access, type checking, pattern matching, and serialization should consume the same metadata instead of reparsing declaration syntax.

- Decision: built-in Result/Option behavior is enum-backed compatibility, not a separate ADT model.
  - Rationale: `Ok`, `Err`, `Some`, `None`, and `?` keep their user-facing convenience while sharing the same nominal enum identity rules as user declarations.
  - Consequence: User-defined variants with the same names are ordinary enum variants unless they carry the built-in enum identity.

## Risks / Trade-offs
- A clean break from legacy ADT declarations is less compatible with old design sketches, but it avoids two public sum-type models.
- Beta status is conservative even though the main contract is implemented; it leaves room for enum methods, richer pattern forms, custom protocols, and optimizer work without over-promising stability.
- Nominal identity across cache and serialization boundaries is stricter than display-string identity, but it prevents same-name variants from different declarations from being treated as interchangeable.
- Bare enum variant patterns are convenient, but ambiguity diagnostics and qualification guidance are necessary when different enums share variant names.

## Migration Plan
- Treat simple enum declarations as the unit-variant subset of enum ADTs.
- Replace legacy Gene-expression ADT declarations with `enum` declarations using colon generic parameters and named payload fields.
- Keep built-in Result/Option shortcuts as enum-backed compatibility for existing code that uses `Ok`, `Err`, `Some`, `None`, and `?`.
- Migrate quoted legacy Result/Option-shaped Gene values to real enum values before relying on enum ADT type boundaries or patterns.
- Update docs and examples to use enum-qualified forms where custom variants could conflict with built-in names.

## Open Questions
- The stable-core promotion criteria for enum ADTs remain outside this change.
- The syntax and semantics for enum methods, guard/or/as patterns, custom `?` protocols, and optimizer specialization remain open refinements.
