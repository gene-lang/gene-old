## Context
Gene already has tail rest forms such as `[items...]` in examples and tests, and collection spread syntax already treats `name...` and `name ...` as equivalent postfix spellings. Matcher comments also imply non-tail rest patterns such as `[a... b]`. The current runtime binder and type checker do not implement those semantics consistently.

This change needs a design because it touches a hot path in the VM argument binder and a cross-cutting representation in the type checker.

## Goals / Non-Goals
- Goals:
  - Define one clear positional rest-binding model for function parameters and destructuring patterns.
  - Make standalone postfix `...` in matcher contexts behave consistently with existing spread ergonomics.
  - Keep runtime binding linear and avoid aggregate argument objects or matcher backtracking.
  - Align call-site type checking with runtime binding semantics.
- Non-Goals:
  - Add multiple positional rest binders in one matcher.
  - Add anonymous positional `...` matchers with no binding name.
  - Change keyword splat semantics beyond confirming compatibility with positional rest.
  - Introduce a new VM instruction or a generalized backtracking pattern engine.

## Decisions
- Decision: allow exactly one named positional rest binder per matcher.
  - Supported spellings are `name...` and `name ...`.
  - A bare `...` without a preceding named positional binder is invalid in matcher contexts.
  - Multiple positional rest binders in the same matcher are invalid.

- Decision: use prefix/start plus suffix/end matching.
  - Positional binders before the rest binder match from the start of the argument/value list.
  - Positional binders after the rest binder match from the end of the argument/value list.
  - The rest binder receives the contiguous middle slice, which may be empty.
  - This preserves deterministic semantics for non-tail forms such as `[head rest... tail]` and `[a ... b]`.

- Decision: keep default values local to their fixed segment.
  - A fixed positional binder with a default consumes an explicit value when one is available in its prefix or suffix segment.
  - Otherwise it falls back to its default.
  - This prevents a rest binder from greedily swallowing values that visually belong to a fixed suffix.

- Decision: preserve the no-aggregate-object performance constraint.
  - Function argument binding must continue to operate directly on the stack or split positional/keyword inputs.
  - The runtime binder may precompute a single rest index and suffix bounds, but it must not allocate a temporary aggregate argument object just to perform matching.
  - The implementation should remain linear in the number of parameters and arguments.

- Decision: preserve rest position in the type system.
  - Function types must carry the position of the positional rest binder instead of assuming the last positional parameter is variadic.
  - Untyped rest binders default to `(Array Any)`.
  - For call-site checking, fixed prefix and suffix parameters are validated at their actual positions after splitting around the rest binder.
  - When the rest binder has type `(Array T)`, the consumed middle arguments are validated against `T` at compile time.

- Decision: keep keyword splat behavior unchanged.
  - Existing keyword splat bindings such as `^rest...` continue to collect unmatched keyword arguments into a map.
  - Positional rest binding only changes positional matching semantics.

## Risks / Trade-offs
- Restricting matchers to one positional rest binder is less expressive than a fully general splat system, but it keeps semantics deterministic and the binder fast.
- Preserving rest position in function types adds representation complexity, but it removes the current mismatch between call typing and runtime binding.
- Validating middle arguments against `(Array T)` improves soundness, but it slightly increases compile-time work for typed variadic calls.

## Migration Plan
- Keep existing tail rest forms working unchanged.
- Treat `name ...` as a compatibility spelling for `name...` in matcher contexts.
- Raise clear compile-time errors for bare `...` or multiple positional rest binders so invalid patterns fail early instead of misbinding at runtime.

## Open Questions
- Whether typed rest syntax should continue to mean “type of the bound array” or gain a shorthand for element type only. This proposal keeps the bound-array interpretation for compatibility.
