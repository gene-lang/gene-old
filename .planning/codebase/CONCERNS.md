# Codebase Concerns

**Analysis Date:** 2026-04-09

## Tech Debt

**Exception wrapping and message inference complexity:**
- Issue: Recent exception handling changes (commits `fe63b99`, `183b767`, `e43d791`) introduced multi-level exception wrapping with class inference from error message patterns. The `wrap_nim_exception` function must handle both allocation-light wrapping and graceful fallbacks when exception class is NIL.
- Files: `src/gene/types/helpers.nim` (lines 238-330), `src/gene/vm/exec.nim` (line 6691)
- Why: Performance/resilience concern during exception handling cascades, where an exception during exception wrapping could cause secondary failures.
- Impact: Fragile exception handling path during VM execution; incorrect exception class inference could mask root causes.
- Fix approach: Add roundtrip tests for all exception-from-message inference cases; simplify message pattern matching to handle false positives gracefully.

**Large monolithic VM execution core:**
- Issue: `src/gene/vm/exec.nim` (6726 lines) contains the entire VM instruction loop with dense case statements covering 100+ instruction types, mixed control flow, exception handling, and debugging code.
- Files: `src/gene/vm/exec.nim`
- Why: Historical accumulation of features; performance-oriented design kept as single compilation unit.
- Impact: High complexity makes refactoring risky; regressions in one instruction family can silently break others; debugging new features difficult.
- Fix approach: Continue extraction strategy by instruction family (already done for arithmetic, dispatch); establish strict test requirements per extracted subsystem.

**GIR serialization versioning and compatibility:**
- Issue: Serialization format has explicit version field (header.version in `src/gene/gir.nim:643`) and ABI marker validation, but constant pooling is disabled (line 672 TODO) and value serialization is incomplete for some value kinds.
- Files: `src/gene/gir.nim` (lines 640-680, 747-760)
- Why: Constant pooling disabled due to earlier issues; not all value kinds have serialization support.
- Impact: GIR cache behavior unpredictable; cache invalidation unclear; may silently load stale/incompatible bytecode.
- Fix approach: Implement versioning bump discipline; add comprehensive round-trip tests before re-enabling constant pooling; add version mismatch recovery path.

**Module import autoload heuristics:**
- Issue: Global helpers (`start_server`, `respond`, etc.) are hardcoded in extension module loading; genex resolution relies on search-path heuristics and fallback to GENE_HOME env var.
- Files: `src/gene/vm/module.nim` (lines 900-945), `src/gene/vm/exec.nim` (lines 3630), `src/genex/http.nim` (genex_extension_loader hook)
- Why: Early design for convenience; now creates inconsistency between namespaced and global call paths.
- Impact: New extensions may fail silently if names aren't in hardcoded list; behavior differs based on environment variables.
- Fix approach: Move to declarative extension metadata (e.g., extension registers its exported globals at load time); require explicit namespace imports for clarity.

**Scope lifetime tracking incomplete:**
- Issue: Frame code contains disabled scope ownership tracking (TODO at `src/gene/types/core/frames.nim:66`). Scope lifetime is managed by IkScopeEnd but frame.scope is not freed, relying on GC.
- Files: `src/gene/types/core/frames.nim` (lines 58-71), `src/gene/vm/exec.nim` (IkScopeEnd handler)
- Why: Manual memory management combined with GC creates complex lifetime semantics; scope chains can be deep in nested functions.
- Impact: Potential scope memory accumulation; unclear when scopes are eligible for cleanup; may interact poorly with async/thread code.
- Fix approach: Implement deterministic scope cleanup via explicit free calls at scope exit; add scope lifetime regression tests in async contexts.

## Known Bugs

**Exception variable ($ex) not accessible in catch blocks:**
- Symptoms: Catch block catches exception but has no way to access the caught exception value.
- Trigger: Using `(try ... (catch *) ...)`; caught exception is inaccessible within catch body.
- Files: `src/gene/vm/exec.nim` (line 3961 TODO)
- Root cause: Catch handler normalizes exception but doesn't bind it to any variable.
- Workaround: Rethrow with modified state; use external state to pass exception info.
- Impact: Reduces utility of structured exception handling.

**Pattern matching features partially disabled/incomplete:**
- Symptoms: Pattern matching tests exist but match-related tests are limited in scope.
- Trigger: Using advanced pattern matching forms beyond simple argument/array patterns.
- Files: `tests/integration/test_pattern_matching.nim` (lines 50-150), `src/gene/compiler/operators.nim`
- Root cause: Implementation incomplete in compiler and VM instruction support.
- Workaround: Limit usage to currently supported patterns (simple destructuring).
- Impact: Regressions can slip in when touching compiler/VM areas.
- Current status: Basic patterns work; advanced features (destructuring, guards) incomplete.

**Stack overflow error message not propagated correctly in some paths:**
- Symptoms: Stack overflow occurs (message "Stack overflow: frame stack exceeded 256...") but sometimes appears as generic runtime error.
- Trigger: Deep recursion or rapid frame allocation in cross-module variable resolution.
- Files: `src/gene/types/core/frames.nim` (line 133), `src/gene/vm/exec.nim` (IkVarResolve handler)
- Root cause: Stack overflow detection in frame pool; variable resolution stack chain can trigger independently.
- Workaround: Avoid deep cross-module closures with captured state.
- Impact: Difficult to diagnose stack exhaustion issues.

## Security Considerations

**Dynamic extension loading from relative/env-driven paths:**
- Risk: Extension loader searches `./build/lib<name>.*`, then `$GENE_HOME/build/lib<name>.*`, then relative to app binary. Untrusted working directory could cause wrong extension to be loaded.
- Files: `src/gene/vm/module.nim` (lines 894-913), `src/gene/vm/extension.nim` (lines 34-41 dlopen)
- Current mitigation: Explicit filename convention (lib prefix); namespace validation after load; file existence check before dlopen.
- Recommendations: 
  - In production, prefer absolute trusted paths over relative search.
  - Validate file ownership/permissions before dlopen on POSIX.
  - Add extension signature verification when loading from non-trusted roots.
  - Document security implications in extension loading guide.

**OpenAI/Anthropic debug logging may expose response metadata:**
- Risk: Debug logging includes response headers and body snippets; response metadata (timing, retry counts) could leak to logs if debug mode active.
- Files: `src/genex/ai/openai_client.nim`, `src/genex/ai/streaming.nim` (debug output paths)
- Current mitigation: Request headers redacted in logging; debug output only with debug flag.
- Recommendations:
  - Audit all debug output for response metadata leaks.
  - When handling regulated data (PII, PHI), ensure response logging is off by default.
  - Consider structured logging with automatic field redaction.

**Database connection string could contain passwords:**
- Risk: Connection string passed as Value may include password; error messages could log full connection string.
- Files: `src/genex/sqlite.nim` (line 69 open), `src/genex/postgres.nim` (connection code)
- Current mitigation: Exception messages use generic error; no explicit logging of connection strings.
- Recommendations: Add connection string redaction for error messages; validate no passwords in logs.

## Performance Bottlenecks

**Allocation pressure in VM hot paths remains high:**
- Problem: Despite frame pooling, allocation remains a top hotspot in benchmarks. Many value allocations, sequence allocations in dispatch paths.
- Measurement: Documented in previous performance analysis.
- Files: `src/gene/types/core/frames.nim` (frame pool), `src/gene/vm/dispatch.nim` (method dispatch allocations), `src/gene/stdlib/core.nim` (string operations)
- Cause: Repeated object creation in instruction execution loops; sequence allocations for arguments, return values.
- Current mitigation: Frame pooling implemented; value object pooling partial.
- Improvement path: 
  - Implement sequence pooling for common argument counts (2, 3, 4 args).
  - Use arena allocators for short-lived objects in tight loops.
  - Profile with flame graphs to identify remaining hotspots.

**SQLite connection table access contention:**
- Problem: Global connection table uses single lock (`connection_lock`); each connection operation acquires table lock then connection-specific lock (double locking). High concurrent connection churn could stall.
- Measurement: Not quantified; potential issue if many concurrent DB operations.
- Files: `src/genex/sqlite.nim` (lines 27-28 global lock, 75 per-connection lock, 80-83 dual-lock pattern)
- Cause: Correctness-first design; global table shared across all worker threads.
- Current mitigation: Locks are fast; contention unlikely unless extreme concurrency.
- Improvement path:
  - Profile under high concurrent load (100+ connections).
  - Consider lock-free structure (atomic CAS-based ID generation).
  - Reduce global-lock hold time (move table lookup outside lock if possible).

**HTTPServer pending requests lock contention:**
- Problem: Global `pending_lock` protects shared pending request queue; multiple threads may contend during request dispatch.
- Files: `src/genex/http.nim` (pending_lock, withLock usage)
- Cause: Synchronization around thread-pool work queue.
- Current mitigation: Contention expected to be low in normal workloads.
- Improvement path: Add request queue backpressure metrics; use lock-free queue if contention confirmed.

## Fragile Areas

**Thread/channel lifecycle with manual state management:**
- Why fragile: Thread IDs, secrets, state enum, and message routing are tightly coupled. Channel creation/destruction must match thread lifecycle.
- Files: `src/gene/vm/thread_native.nim` (thread management), `src/gene/types/core/threads.nim` (ThreadState, channel structures)
- Common failures: Leaked thread slots; incorrect state transitions; message routed to closed thread.
- Safe modification: Keep changes small; add regression tests in `tests/integration/test_thread.nim`; verify state machine transitions.
- Test coverage: Exists but includes TODOs for advanced scenarios (spawn_return with args, nested spawn_return, message passing, thread.join, thread parent).

**GIR serialization ABI compatibility surface:**
- Why fragile: Multiple value kinds and type metadata fields must stay ABI-compatible. Changes to Value union, instruction enum, or class metadata need version bump + migration logic.
- Files: `src/gene/gir.nim` (serialization format), `src/gene/types/type_defs.nim` (Value enum, instruction enum)
- Common failures: Deserialization reads wrong byte offsets; serialized cache becomes unreadable after code changes.
- Safe modification: Always bump GIR_VERSION when changing serialization format; add round-trip tests before merging; run GIR cache compatibility check in CI.
- Test coverage: Present in `tests/` but gaps remain for not-yet-implemented value kinds (some value type serialization paths may be stubs).

**Compiler pipeline with many interdependent transformation stages:**
- Why fragile: Compiler applies transformations in specific order: import resolution → type checking → macro expansion → bytecode compilation. If stages execute out-of-order or skip, type information gets corrupted.
- Files: `src/gene/compiler/pipeline.nim` (lines 400+), `src/gene/compiler.nim` (compilation entry)
- Common failures: Type inference fails on macro-expanded code; import cycles; incorrect scope binding in nested functions.
- Safe modification: Add assertions for invariants at stage boundaries; create tests that cover interdependencies.
- Test coverage: Exists in `tests/integration/` but edge cases (macro + imports, type checks after macro expansion) partially covered.

**Exception handler stack and control flow interaction:**
- Why fragile: Exception handler stack (try/catch/finally) must stay in sync with PC and frame stack. Break/continue/return in finally block have special rules.
- Files: `src/gene/vm/exec.nim` (IkTryStart through IkFinallyEnd handlers, lines 3930-4050)
- Common failures: Exception lost after finally block; return in finally doesn't prevent exception propagation; incorrect value left on stack.
- Safe modification: Add detailed comments for each control flow case; test all combinations (try+catch, try+finally, try+catch+finally with break/continue/return in each).
- Test coverage: Partial; finally block tests exist but interaction with all control flow forms incomplete.

## Scaling Limits

**Fixed thread pool capacity:**
- Current capacity: Bounded by THREAD_STATE_MAX (thread state table size in type_defs.nim).
- Files: `src/gene/vm/thread_native.nim`, `src/gene/types/core/threads.nim` (thread pool state), `src/gene/types/type_defs.nim` (array bounds)
- Limit: Cannot exceed fixed pool size; failure to allocate thread ID = runtime error.
- Symptoms at limit: "Failed to allocate thread ID" error; spawning new threads fails.
- Scaling path: Make thread pool size configurable at VM creation time; implement queue-based thread pool with elastic worker scaling.

**Frame stack depth limit:**
- Current capacity: Frame stack error triggers at 256 frames (see `src/gene/types/core/frames.nim:133`).
- Files: `src/gene/types/core/frames.nim`, `src/gene/vm/exec.nim`
- Limit: Mutual recursion or deep call chains hit hard limit.
- Symptoms at limit: "Stack overflow: frame stack exceeded 256..." error.
- Scaling path: Increase hard limit (may require tuning for memory), implement tail call optimization per-function, document TCO requirements for recursive code.

**Module cache unbounded growth:**
- Current capacity: Global module cache (`ModuleCache` in `src/gene/vm/module.nim:34`) grows unbounded as modules are loaded.
- Files: `src/gene/vm/module.nim` (ModuleCache), `src/genex/ai/memory_store.nim` (SQLite event table growth)
- Limit: Long-running processes may accumulate large module cache; memory_store event table unbounded.
- Symptoms at limit: Growing memory usage; cache lookups still O(1) but table size unbounded.
- Scaling path: Implement cache eviction policy (LRU by last access); add memory_store archival/cleanup policies.

## Dependencies at Risk

**llama.cpp submodule integration drift:**
- Risk: External API/ABI changes in llama.cpp can break local LLM shim; submodule pins specific commit that may diverge from current main.
- Files: `tools/llama.cpp` (submodule), `src/genex/llm/shim/gene_llm.cpp` (C++ shim)
- Impact: Local inference features break after `git submodule update`; may require urgent patching.
- Current mitigation: Submodule pinned to specific commit; shim has compile-time version checks.
- Migration plan: 
  - Maintain compatibility tests for llama.cpp version changes.
  - Document LLM shim compatibility matrix (llama.cpp version → shim version).
  - Consider wrapping llama.cpp in stable ABI layer to decouple from internal changes.

**db_connector version/behavior changes:**
- Risk: `db_connector` package (imported in `src/genex/sqlite.nim:2`) may have breaking API/behavior changes; sqlite3 module ABI changes.
- Files: `src/genex/sqlite.nim`, `src/genex/postgres.nim` (db_connector clients), `gene.nimble` (dependency)
- Impact: Database I/O regressions; SQL binding differences; prepared statement compatibility.
- Current mitigation: Tests cover basic operations; nimble pins versions.
- Migration plan: Keep extension tests green; add parameter edge-case tests; document db_connector version requirements in README.

## Missing Critical Features

**Module/package management ergonomics:**
- Problem: Module resolver has expanded significantly; user-facing packaging workflow, version management, and dependency resolution documentation still evolving.
- Current workaround: Manual path configuration; project-local conventions.
- Blocks: Predictable multi-project distribution, lower friction onboarding, stable package ecosystem.
- Implementation complexity: Medium to high (resolver edge-cases, tooling, docs alignment).
- Files: `src/gene/vm/module.nim` (module resolution logic).

**OOP class semantics completeness:**
- Problem: Constructor chaining, inheritance edge cases, method dispatch on inherited methods need broader coverage.
- Current workaround: Use supported subset; avoid advanced unsupported patterns.
- Blocks: Predictable OOP behavior in larger programs; library design without workarounds.
- Implementation complexity: Medium to high.
- Files: `src/gene/vm/dispatch.nim` (method dispatch), `src/gene/compiler/operators.nim` (class compilation).

**Complete pattern matching implementation:**
- Problem: Advanced pattern matching (guards, nested patterns, match expressions beyond simple destructuring) incomplete.
- Current workaround: Limit to basic destructuring patterns.
- Blocks: Elegant functional programming patterns; exhaustive match checking.
- Implementation complexity: Medium to high.
- Files: `tests/integration/test_pattern_matching.nim`, `src/gene/compiler/` (pattern compilation).

## Test Coverage Gaps

**Disabled/incomplete feature tests:**
- What's not fully tested: Template features (for loops in templates), full pattern matching, range behaviors, thread flows (spawn_return, message passing, thread.join).
- Files: `tests/integration/test_template.nim` (lines 68-88 TODO), `tests/integration/test_pattern_matching.nim` (basic tests only), `tests/integration/test_range.nim` (lines 36-95 TODO), `tests/integration/test_thread.nim` (lines 199-288 TODO)
- Risk: Regressions slip in when touching related compiler/VM areas; incomplete features may break silently.
- Priority: High
- Difficulty to test: Medium (some features still being implemented).

**Optional integration paths not in default CI:**
- What's not fully tested: PostgreSQL integration, llama.cpp local inference, advanced AI features in CI.
- Files: `gene.nimble` (task comments/flags), `.github/workflows/build-and-test.yml`
- Risk: Environment-specific regressions (e.g., postgres behavior changes) discovered late.
- Priority: Medium
- Difficulty to test: Medium (requires service/tooling setup in CI matrix).

**Exception handling edge cases:**
- What's not fully tested: All combinations of break/continue/return in try/catch/finally; exception in exception handler; exception during exception wrapping.
- Files: `tests/integration/test_exception.nim` (TODO at lines 69)
- Risk: Silent exception loss or incorrect control flow in error paths.
- Priority: High
- Difficulty to test: Medium (requires careful control flow testing).

**GIR round-trip compatibility:**
- What's not fully tested: Serialization round-trip for all value kinds; GIR versioning with backward compatibility; cache invalidation behavior.
- Files: `tests/test_gir.nim` (if exists) or missing.
- Risk: GIR cache contains stale bytecode; format changes break without migration path.
- Priority: High
- Difficulty to test: Medium (requires GIR versioning strategy).

---

*Concerns audit: 2026-04-09*
*Updated to reflect recent exception handling changes and scalability limits*
