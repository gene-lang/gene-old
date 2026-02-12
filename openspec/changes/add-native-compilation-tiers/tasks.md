## 1. Implementation
- [ ] 1.1 Add a native tier enum to VM state and initialize defaults.
- [ ] 1.2 Make native dispatch tier-aware (`never`/`guarded`/`fully-typed`) with explicit deopt fallback.
- [ ] 1.3 Add `--native-tier` CLI support for `run`, `eval`, and `pipe`; keep `--native-code` as guarded shorthand.
- [ ] 1.4 Add/extend tests for tier behavior and deopt fallback.

## 2. Validation
- [ ] 2.1 Run targeted native tests (`tests/test_native_trampoline.nim`).
- [ ] 2.2 Run affected CLI tests (`tests/test_cli_run.nim`).
