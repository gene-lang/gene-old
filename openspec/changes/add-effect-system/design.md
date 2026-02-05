# Effect System Design

## Goals
- Represent effects in function types and declarations.
- Enforce effect boundaries in the type checker.
- Keep syntax close to `docs/ai-first.md` while staying parseable by the current reader.

## Non-Goals (Initial Milestone)
- Effect inference from body.
- Effect handlers (`with-handler`) or effect polymorphism.
- Runtime enforcement or optimizer integration.

## Representation
- Extend `TypeExpr` for `TkFn` to include `effects: seq[string]`.
- Treat effects as a set of symbol names. Canonicalize by de-duplicating and preserving order of first appearance.
- `nil` effects means "unknown" (no effect constraints), while empty `@[]` means explicitly pure. For this milestone, function definitions default to explicit purity when no `!` is provided.

## Syntax
- Function definition:
  - `(fn name [args] -> Return ! [Db Http] body...)`
  - `! [Effects...]` is optional and must appear after an optional `-> Return`.
- Function type expression:
  - `(Fn [A B] R ! [Db])` (single form that parses today).
  - The doc form `(Fn [A B] R) ! [Db]` is deferred.

## Type Checker Rules
- Maintain an `effect_stack` in `TypeChecker` to track allowed effects for the current function body.
- When entering a function (fn/block/ctor/method), push its declared effects.
- When calling a function with declared effects, ensure all callee effects are included in the current effect set.
- Top-level (non-function) has no effect restrictions.
- Function type unification treats effect lists as compatible when the actual function effects are a subset of the expected effects; unknown effects are treated as compatible.

## Compiler / Metadata
- Add `TC_EFFECTS_KEY` to annotate function AST nodes with their declared effects.
- Preserve effects in generated function genes (methods/ctors) similar to param/return annotations.

## Tests (Initial)
- Effect annotation parsing on function definitions and `Fn` type expressions.
- Error when calling an effectful function from a pure function.
- Success when caller declares a superset of effects.
