# Codebase Concerns

**Analysis Date:** 2026-02-28

## Tech Debt

**Extension discovery/autoload heuristics:**
- Issue: `genex` resolution relies on search-path heuristics and a small hardcoded set of lazy global symbols
- Files: `src/gene/vm/module.nim`, `src/gene/vm/exec.nim`
- Why: dynamic loading now works, but helper-global autoload (`start_server`, `respond`, etc.) is explicit-name based
- Impact: newly added extension globals may not autoload unless mapped; behavior differs between namespaced and global call styles
- Fix approach: move to declarative extension metadata for exported global helpers (or require explicit namespace usage)

**Large include-driven core files:**
- Issue: high complexity concentrated in `src/gene/vm.nim` and `src/gene/compiler.nim`
- Why: performance-oriented composition plus historical growth
- Impact: fragile refactors and high regression risk in core execution paths
- Fix approach: continue extracting cohesive subsystems with strict tests per instruction family

## Known Bugs

**Stack overflow in cross-module variable resolution:**
- Symptoms: `Stack overflow: frame stack exceeded 256 at pc ... (IkVarResolve)`
- Trigger: exported function captures module-level state and is called cross-module
- Files: documented in `docs/known_issues/var_stack_overflow.md`
- Workaround: avoid this closure pattern / use static prompt workaround in affected code
- Root cause: unresolved scope-chain resolution issue in variable lookup path

**Pattern matching and related features partially disabled:**
- Symptoms: match-related tests are marked TODO/disabled
- Trigger: using not-yet-complete matching forms beyond supported subset
- Files: `tests/test_pattern_matching.nim`, `docs/architecture.md` (pain point note)
- Workaround: limit usage to currently supported patterns
- Root cause: implementation incomplete in compile/VM paths

## Security Considerations

**OpenAI debug logging still exposes non-secret request/response metadata:**
- Risk: request headers are redacted, but debug output still includes full response headers/body snippets
- Files: `src/genex/ai/openai_client.nim`, `src/genex/ai/streaming.nim`
- Current mitigation: secret-bearing request headers are redacted; debug logging only when compiled with debug flag
- Recommendations: optionally redact additional sensitive response metadata in debug logs when handling regulated data

**Dynamic extension load path trust boundary:**
- Risk: extension loader searches relative paths (`build/...`) and env-driven roots (`$GENE_HOME/build/...`)
- Files: `src/gene/vm/module.nim`, `src/gene/vm/extension.nim`
- Current mitigation: explicit filename conventions (`lib<name>.<ext>`) and namespace validation after load
- Recommendations: prefer absolute trusted roots in production and avoid running from untrusted working directories

## Performance Bottlenecks

**Allocation pressure in VM hot paths:**
- Problem: allocation remains a top hotspot despite frame pooling improvements
- Measurement: documented in `docs/performance.md` (allocation still primary hotspot)
- Cause: repeated object/sequence allocation in runtime paths
- Improvement path: sequence pooling/arena strategies listed in `docs/performance.md`

**SQLite registry lock + per-connection lock contention:**
- Problem: connection table access uses a global lock, and each connection serializes its own query/exec operations
- Files: `src/genex/sqlite.nim` (`connection_lock`, `wrapper.lock`)
- Cause: correctness-first synchronization around shared table and connection handles
- Improvement path: reduce global-lock hold time further and validate contention under high concurrent connection churn

## Fragile Areas

**Thread/channel lifecycle code:**
- Why fragile: manual allocation, channel lifecycle, and secret/thread metadata rotation are tightly coupled
- Files: `src/gene/vm/thread.nim`
- Common failures: leaked/incorrect thread state and subtle concurrency bugs
- Safe modification: keep changes small, add regression tests in `tests/test_thread*.nim`
- Test coverage: exists but includes TODOs for several advanced scenarios

**GIR serialization compatibility surface:**
- Why fragile: many value kinds and type metadata fields must stay ABI-compatible
- Files: `src/gene/gir.nim`
- Common failures: serialization/deserialization mismatch or stale cache behavior
- Safe modification: version bump discipline + round-trip tests and compatibility checks
- Test coverage: present but gaps remain for not-yet-implemented value kinds

## Scaling Limits

**Thread pool capacity:**
- Current capacity: fixed worker slot limits (thread-pool constants and arrays)
- Files: `src/gene/vm/thread.nim`, type-level thread limits in runtime types
- Limit: bounded thread model; no elastic scaling
- Symptoms at limit: failure to allocate new worker thread IDs
- Scaling path: configurable pool sizing and queue/backpressure strategies

## Dependencies at Risk

**llama.cpp integration drift risk:**
- Risk: external API/ABI changes can break local LLM shim build/runtime
- Files: `tools/llama.cpp` submodule, `src/genex/llm/shim/gene_llm.cpp`
- Impact: local inference features break or require urgent patching
- Migration plan: pin/update submodule intentionally and keep shim compatibility tests

**Database connector compatibility:**
- Risk: behavior/version changes in `db_connector` affect sqlite/postgres extensions
- Files: `src/genex/sqlite.nim`, `src/genex/postgres.nim`, `gene.nimble`
- Impact: database I/O regressions and SQL binding differences
- Migration plan: keep extension tests green and add edge-case parameter tests

## Missing Critical Features

**Module/package ergonomics and stabilization:**
- Problem: resolver coverage has expanded significantly, but user-facing packaging workflow/docs are still evolving
- Current workaround: rely on current resolver behavior and project-local conventions
- Blocks: predictable multi-project distribution and lower-friction onboarding
- Implementation complexity: medium to high (resolver edge-cases, tooling/docs alignment)

**Richer class semantics coverage:**
- Problem: constructors/inheritance/dispatch edge cases need broader coverage
- Current workaround: use supported subset and avoid advanced unsupported cases
- Blocks: predictable OOP behavior across larger programs
- Implementation complexity: medium to high

## Test Coverage Gaps

**Disabled or TODO-heavy feature tests:**
- What's not fully tested: template features, full pattern matching, range behaviors, some thread flows
- Files: `tests/test_template.nim`, `tests/test_pattern_matching.nim`, `tests/test_range.nim`, `tests/test_thread.nim`
- Risk: regressions can slip in when touching related compiler/vm areas
- Priority: High
- Difficulty to test: medium (some features still being implemented)

**Optional integration paths in CI:**
- What's not fully tested: postgres/llm paths in default CI profile
- Files: `gene.nimble` task comments/flags, `.github/workflows/build-and-test.yml`
- Risk: environment-specific regressions discovered late
- Priority: Medium
- Difficulty to test: medium (requires service/tooling setup in CI)

---
*Concerns audit: 2026-02-28*
*Update as issues are fixed or new ones discovered*
