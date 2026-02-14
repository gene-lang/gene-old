## 1. OpenSpec
- [x] 1.1 Define formatter CLI behavior and canonical style requirements.
- [x] 1.2 Validate proposal with `openspec validate add-gene-fmt-canonical-formatter --strict`.

## 2. Implementation
- [ ] 2.1 Add `src/gene/formatter.nim` with deterministic AST-to-source formatting.
- [ ] 2.2 Preserve comment placement relative to nearby forms while keeping formatted structure canonical.
- [ ] 2.3 Add `src/commands/fmt.nim` command with in-place and `--check` modes.
- [ ] 2.4 Wire `fmt` command into CLI dispatch in `src/gene.nim`.
- [ ] 2.5 Add tests under `testsuite/fmt/` for canonical/no-op, sorting, indentation, check mode, nesting, and comment preservation.
- [ ] 2.6 Integrate formatter tests into `testsuite/run_tests.sh`.

## 3. Validation
- [ ] 3.1 Run formatter-focused tests.
- [ ] 3.2 Run `./testsuite/run_tests.sh`.
