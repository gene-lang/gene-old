## Why

Native execution is currently controlled by a single boolean (`--native-code`), which is too coarse for staged rollout and predictable performance behavior. We need explicit runtime tiers so developers can choose safety/perf tradeoffs and understand fallback semantics.

## What Changes

- Add explicit native compilation tiers:
  - `never`
  - `guarded`
  - `fully-typed`
- Define deoptimization behavior for tiered native execution.
- Add CLI support (`--native-tier`) to `run`, `eval`, and `pipe`.
- Keep backward compatibility for `--native-code` as shorthand for `guarded`.
- Add tests for tier selection and fallback behavior.

## Impact

- Affected specs: `native-compilation-tiers`
- Affected code:
  - `src/gene/types/type_defs.nim`
  - `src/gene/types/helpers.nim`
  - `src/gene/vm/core_helpers.nim`
  - `src/gene/vm/native.nim`
  - `src/commands/run.nim`
  - `src/commands/eval.nim`
  - `src/commands/pipe.nim`
  - `tests/test_native_trampoline.nim`
