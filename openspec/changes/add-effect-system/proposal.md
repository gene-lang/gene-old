## Why
Gene's AI-first vision requires explicit effect tracking in function signatures, but effects are currently not represented or enforced. This blocks the design in `docs/ai-first.md` and makes purity boundaries unverifiable.

## What Changes
- Add effect annotations (`! [Effect ...]`) to function definitions and function type expressions.
- Represent effects in the type system and propagate them through the compiler metadata.
- Add basic effect checking in the type checker (callers must allow callee effects).
- Add focused tests for effect annotation parsing and enforcement.

## Impact
- Affected specs: new `effect-system` capability (OpenSpec change)
- Affected code: `src/gene/type_checker.nim`, `src/gene/compiler.nim`, `src/gene/types/value_core.nim`, `src/gene/types/runtime_types.nim`, `src/gene/types/type_defs.nim`, tests under `testsuite/`
