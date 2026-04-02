## Why
Gene already parses and checks some function type information, but the current shape is too lossy for the signatures we want to support. Function descriptors flatten parameters into a positional list plus rest/keyword booleans, which cannot faithfully represent canonical forms such as `(Fn)`, `(Fn -> Int)`, `(Fn [Int ... String])`, or `(Fn [^a Int ^b String ^... Any Int ... String] -> String)`.

## What Changes
- Define canonical surface syntax for function types using optional argument and return clauses, with omitted returns defaulting to `Any`.
- Require function-type metadata to preserve parameter kind, keyword labels, variadic position, keyword-rest value type, and explicit `Void` returns.
- Define one unified callable model for functions and methods, with `Self` as a special contextual receiver type.
- Reserve `self` and `Self` so receiver semantics are not shadowed by user-defined bindings.
- Require function type inference to normalize function definitions, methods, and native signatures into the canonical `Fn` forms.
- Align effect-system and runtime function compatibility specs with the new canonical `Fn` surface.

## Impact
- Affected specs: `type-system`, `runtime-type-validation`, `effect-system`
- Affected code:
  - `src/gene/type_checker.nim`
  - `src/gene/types/type_defs.nim`
  - `src/gene/types/descriptors.nim`
  - `src/gene/types/core/matchers.nim`
  - `src/gene/types/runtime_types.nim`
  - `src/gene/gir.nim`
  - typed-function and GIR tests
