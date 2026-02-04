## Why
Benchmarks need low-overhead timing without extra function-call overhead or user error from missing start values.

## What Changes
- Add special timing variables `$duration_start` and `$duration` backed by VM state.
- Add `time/now_us` native function that returns microsecond epoch time.
- Update Fibonacci benchmark to use `$duration_start`/`$duration`.
- Add tests for the new timing behavior.

## Impact
- Affected specs: time
- Affected code: `src/gene/vm.nim`, `src/gene/types/type_defs.nim`, `src/gene/types/helpers.nim`, `benchmarks/computation/fibonacci.gene`, `testsuite/`.
