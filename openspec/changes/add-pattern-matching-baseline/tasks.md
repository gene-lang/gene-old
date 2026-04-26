## 1. Definition
- [ ] 1.1 Lock remaining semantics (arity/type contract and diagnostics) for argument matching and existing `var` destructuring; confirm current scope/shadowing behavior.
- [ ] 1.2 Update `docs/proposals/future/pattern_matching_design.md` with the finalized Beta subset, exclusions, removed `(match ...)` boundary, and error model.

## 2. Spec
- [ ] 2.1 Add spec deltas describing argument matching, existing destructuring semantics, and the removed standalone `(match ...)` boundary.
- [ ] 2.2 Validate with `openspec validate add-pattern-matching-baseline --strict`.

## 3. Implementation (follow-on)
- [ ] 3.1 Add or preserve targeted diagnostics/tests for invalid Beta-subset destructuring and removed `(match ...)` usage.
- [ ] 3.2 Add tests covering happy paths and mismatch cases for argument binding, `var` destructuring, simple `case/when`, and enum ADT `case` patterns.
