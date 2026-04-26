## 1. Declaration Contract
- [x] 1.1 Canonicalize generic enum declaration heads so `(enum Result:T:E ...)` declares the base enum name `Result`.
- [x] 1.2 Preserve unit variant and payload variant metadata in enum definitions.
- [x] 1.3 Record ordered payload field names and optional field type descriptors for constructor, checker, pattern, and persistence consumers.
- [x] 1.4 Reject malformed enum declarations, duplicate variants, duplicate fields, invalid generic parameters, and invalid field annotations with targeted diagnostics.
- [x] 1.5 Align public docs/specs with `enum` as the only public ADT declaration model.

## 2. Runtime, Checker, and Persistence Semantics
- [x] 2.1 Enforce payload constructor arity, keyword behavior, mixed-call rejection, and annotated field types using enum metadata.
- [x] 2.2 Back built-in `Result`, `Option`, and `?` with canonical enum identities while preserving existing shortcut ergonomics.
- [x] 2.3 Implement enum variant `case` patterns, payload destructuring, ambiguity/arity/unknown diagnostics, and exhaustiveness checks through enum metadata.
- [x] 2.4 Preserve nominal enum identity across imports, GIR cache artifacts, runtime serialization, and tree serialization/hash boundaries.
- [x] 2.5 Reject legacy Gene-expression ADT declarations and quoted legacy Result/Option-shaped values as migration cases rather than alternate ADT values.

## 3. Public Contract and Final Validation
- [x] 3.1 Add and maintain declaration, constructor, type-checker, migration, pattern, identity, serdes, tree-serdes, and GIR regression coverage.
- [x] 3.2 Rewrite public specs/docs and add the runnable public full example plus tracked enum ADT testsuite fixture.
- [x] 3.3 Run final focused regression matrix, strict OpenSpec validation, whitespace check, and stale-claim grep after the public contract artifacts are complete.
