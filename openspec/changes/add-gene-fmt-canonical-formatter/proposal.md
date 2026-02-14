## Why

Gene needs a canonical formatter to make source deterministic for AI tooling, reduce review noise, and enforce a human-readable baseline style.

## What Changes

- Add `gene fmt` CLI command for formatting `.gene` files.
- Support in-place formatting (`gene fmt file.gene`) and check mode (`gene fmt --check file.gene`).
- Define canonical formatting rules: indentation, width wrapping, property ordering, spacing, top-level separation, and deterministic layout decisions.
- Preserve comments in relative position and preserve string literal content exactly.
- Add formatter tests under `testsuite/fmt/` and wire category into the testsuite runner.

## Impact

- Affected specs: `source-formatter`
- Affected code:
  - `src/gene/formatter.nim` (new)
  - `src/commands/fmt.nim` (new)
  - `src/gene.nim`
  - `testsuite/fmt/*.gene` (new)
  - `testsuite/run_tests.sh`
