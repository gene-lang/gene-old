# Future Pattern Matching Design Notes

## Historical prompt

The original design question explored efficient pattern matching over values that are
already on the VM stack as `UncheckedArray[Value]`, with an optional properties
map flag. The motivation remains valid for future optimizer work: argument
matching should avoid constructing an aggregate argument object just to bind
parameters.

Example stack shapes from the original discussion:

- `Stack: [f 1 2]` exposes positional values `[1 2]`.
- `Stack: [f ^p 1 2 3]` exposes properties `{^p 1}` plus positional values `[2 3]`.
- `Stack: [f ^p 1]` exposes properties `{^p 1}` and no positional children.

## Current boundary

The current public Beta subset is not a general pattern-language implementation.
It consists of tested `var` destructuring, argument binding, simple `case/when`,
and enum ADT `case` patterns. The standalone `(match ...)` expression is a
removed surface in the current compiler; users should use `(var pattern value)`
for binding and `(case ...)` for branching. The compiler diagnostic intentionally
says `match has been removed` to steer users away from stale examples.

## Future plan

- Keep the pointer-based idea (`ptr UncheckedArray[Value]` into
  `process_args_direct`) as a future optimization. It would need dedicated
  matcher infrastructure, clear pointer-lifetime rules, and GC/scope safety
  proof before becoming implementation work.
- Preserve the no-aggregate-object constraint for function argument binding.
- Reintroduce a standalone match expression only through a fresh proposal that
  specifies semantics, diagnostics, tests, and migration from the removed form.

## Explicit non-goals for the current Beta cleanup

- Do not reintroduce `(match ...)` while reconciling the Beta contract.
- Do not promote guards, or-patterns, as-patterns, map destructuring, nested
  patterns, or a full pattern language without implementation and focused tests.
- Do not add a new VM matcher instruction until profiling and safety work prove
  it is needed.

## Follow-up questions for any future proposal

- Which inputs are matchable: arrays only, Gene children/properties, maps, enums,
  or arbitrary sequence-like values?
- What is the exact arity contract for each supported input shape?
- Which scope owns new bindings, and how does shadowing interact with existing
  locals?
- What diagnostics are required for type mismatch, arity mismatch, unsupported
  forms, and removed legacy syntax?
