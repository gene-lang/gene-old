## Context
Gene already had runtime enum values and a separate historical ADT story for Result/Option-like values. The unified model makes enum metadata the source of truth for both simple enums and payload-bearing sum types.

This design note exists because the declaration contract crosses compiler parsing, type checking, runtime metadata, and GIR/module metadata.

## Goals / Non-Goals
- Goals:
  - Make `enum` the canonical public ADT declaration form.
  - Support generic enum heads such as `Result:T:E` while storing the base enum name.
  - Store ordered payload field names and optional type descriptors once, on enum member metadata.
  - Provide diagnostics that identify the failing declaration category.
- Non-Goals:
  - Finish constructor arity or field-type enforcement in the declaration slice.
  - Finish Result/Option compatibility cleanup.
  - Finish enum pattern matching or exhaustiveness checking.
  - Finish nominal identity persistence across every module/cache/serialization boundary.

## Decisions
- Decision: `enum` is the only public ADT declaration model.
  - Rationale: Keeping both runtime enums and Gene-expression ADTs would preserve the split this change is removing.
  - Consequence: Docs and specs must not present `(type (Result T E) ...)` as an alternate supported ADT declaration.

- Decision: generic enum declaration parameters use colon syntax on the enum head.
  - Example: `(enum Result:T:E (Ok value: T) (Err error: E))`.
  - Rationale: This matches Gene's existing generic definition style and keeps type usage separate as `(Result Int String)`.

- Decision: canonical enum identity starts from the base declaration name.
  - Example: `Result:T:E` declares `Result` for runtime type names, type-checker lookup, and GIR/module enum metadata.
  - Rationale: Downstream identity and persistence need a stable nominal name rather than a syntax-bearing head string.

- Decision: enum member metadata owns payload field descriptors.
  - Ordered field names and optional field type descriptors are stored on each enum member.
  - Rationale: Constructors, field access, type checking, and pattern matching should all consume the same metadata instead of reparsing declaration syntax.

## Risks / Trade-offs
- A clean break from legacy ADT declarations is less compatible with old design sketches, but it avoids two public sum-type models.
- Recording field type descriptors before full constructor enforcement adds metadata that not every runtime path consumes immediately, but it gives downstream slices a stable contract.
- Keeping pattern matching downstream avoids overclaiming the S01 boundary, but docs must be explicit so future work does not treat hardcoded Result/Option patterns as the model.

## Migration Plan
- Treat simple enum declarations as the unit-variant subset of enum ADTs.
- Keep any temporary Result/Option shortcuts as migration compatibility, not as a separate model.
- Update docs and tests to use enum-qualified forms for the canonical model.
- Implement constructor enforcement, Result/Option cleanup, pattern matching, and identity persistence as follow-on slices.

## Open Questions
- The final user-facing compatibility policy for existing unqualified Result/Option shortcuts is owned by the Result/Option migration slice.
- The final exhaustiveness severity policy is owned by the enum pattern-matching slice.
