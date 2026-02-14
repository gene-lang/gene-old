## 1. OpenSpec
- [x] 1.1 Define formatter behavior with `examples/full.gene` as canonical style oracle.
- [x] 1.2 Validate proposal with `openspec validate rewrite-gene-fmt-golden-style --strict`.

## 2. Implementation
- [x] 2.1 Implement token-level formatter in `src/gene/formatter.nim` with shebang/comment/blank-line preservation.
- [x] 2.2 Implement `gene fmt` command (`src/commands/fmt.nim`) with in-place and `--check` modes.
- [x] 2.3 Wire command registration in `src/gene.nim` and help text updates.
- [x] 2.4 Ensure no trailing whitespace and deterministic output.

## 3. Validation
- [x] 3.1 Build with `PATH=$HOME/.nimble/bin:$PATH nimble build`.
- [x] 3.2 Add/refresh `testsuite/fmt/` tests, including golden-style check for `examples/full.gene`.
- [x] 3.3 Run formatter tests and `bin/gene fmt examples/full.gene --check`.
- [x] 3.4 Run `./testsuite/run_tests.sh`.
