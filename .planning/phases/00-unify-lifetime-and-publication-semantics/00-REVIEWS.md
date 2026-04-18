---
phase: 0
reviewers: [claude, codex]
reviewers_skipped:
  - gemini: "Gemini API 403 PERMISSION_DENIED on authenticated Google project; no OAuth settings"
  - cursor: "cursor binary on this machine is the IDE launcher (cursor-agent headless agent not installed)"
  - opencode: "not installed"
  - qwen: "not installed"
  - coderabbit: "not installed"
reviewed_at: 2026-04-18
branch: actor
commits_reviewed:
  - 15c7adf "Actor support"
  - cbe098a "Preserve constructor and module runtime semantics under local-def compilation"
plans_reviewed:
  - 00-01-PLAN.md  # P0.1 RC unification — NOT DELIVERED (no SUMMARY.md, no diff)
  - 00-02-PLAN.md + 00-02-SUMMARY.md  # P0.2 publication
  - 00-03-PLAN.md + 00-03-SUMMARY.md  # P0.3 thread runtime
  - 00-04-PLAN.md + 00-04-SUMMARY.md  # P0.4 immutable strings
  - 00-05-PLAN.md  # P0.5 bootstrap + sweep — NOT DELIVERED
verdict: "Phase 0 partially delivered (P0.2/P0.3/P0.4). P0.1 + P0.5 undelivered. Not yet a safe substrate for ACT-01..04."
risk: HIGH
---

# Cross-AI Plan Review — Phase 0: Unify lifetime and publication semantics

Two reviewers (Claude, Codex) independently reviewed the phase plans and the
delivered `actor` branch. Both reached the same top-level verdict: the phase
is only partially delivered and is **not yet a safe substrate for ACT-01..04**.
Codex also compiled and ran the targeted regression suites
(`test_scope_lifetime`, `test_thread`, `test_stdlib_string`,
`test_native_trampoline`, `test_cli_gir`) — all pass on branch `actor`.

Full per-reviewer text and a consensus synthesis follow.

---

## Claude Review

### Summary

Phase 0 delivers three of its five planned workstreams (P0.2 publication
locks, P0.3 thread-channel correctness, P0.4 string immutability), with sound
implementation in the delivered plans. However, two critical workstreams remain
undelivered: P0.1 (RC lifetime unification) and P0.5 (bootstrap publication
discipline). The dual ref-counting model — manual `retain`/`release` in
`value_ops.nim` coexisting with ARC-managed hooks in `memory.nim` — is the
original cause of the unsafe multi-threaded sharing that Phase 0 was designed
to eliminate, and it persists unchanged. The publication guards added in P0.2
are correctly implemented and directly enable safe multi-reader dispatch;
P0.3's per-thread channel polling and `MtRegisterCallback` close real data
races in the async executor. P0.4's return-new `String.append` semantics are
correct and tested. The phase is **not ready to gate actor phases ACT-01..04**
until P0.1 and P0.5 are completed: any actor that shares a `Value` containing
an array or map across threads operates under an unsynchronized retain path.

### Strengths

- **P0.2 double-checked locking is correct.** `prepare_native_ctx` in
  `src/gene/vm/native.nim:99–117` writes `native_entry`, descriptors, and the
  `returnFloat`/`returnValue`/`returnString` flags before setting
  `native_ready = true`, satisfying the store-ordering requirement. The outer
  `acquire`/release guard prevents the second reader from observing a partial
  write. PUB-01/02/03 are satisfied.
- **Publication helper centralizes the invariant.** `publish_compiled_body` in
  `src/gene/types/helpers.nim` enforces `ensure_inline_caches_ready` inside the
  lock, making it structurally impossible to publish a `CompilationUnit` whose
  `inline_caches` length doesn't match `instructions.len`. The
  `get_inline_cache` template's raise-on-nil path in `exec.nim:4–9` converts
  any future breakage into a hard crash rather than a silent OOB read.
- **P0.3 removes the hard-coded thread-0 assumption.**
  `src/gene/vm/async_exec.nim:147` now captures `current_thread_id` and polls
  only that thread's slot. A spawned worker must not drain another thread's
  mailbox. The prior `0` literal was a latent race for any multi-threaded
  workload.
- **`MtRegisterCallback` is a clean design.** Restricting remote
  `.on_message` registration to `VkNativeFn`
  (`src/gene/vm/thread_native.nim:365–382`) is a pragmatic and safe constraint:
  Nim closures captured in a `VkFunction` may hold GC-managed pointers that are
  not safe to hand across threads. Explicitly rejecting them at registration
  time is correct.
- **STR-01 is properly addressed.** `stdlib/strings.nim:27–47` allocates a
  new buffer, copies both operands, and returns a new `Value`. The alias-safety
  test in `tests/integration/test_stdlib_string.nim` verifies that the original
  string is unmodified after append — a meaningful regression guard.
- **Incremental risk management.** Delivering P0.2–P0.4 in isolation is a
  defensible sequencing choice; publication locks and thread-channel fixes
  reduce the blast radius of the remaining P0.1 gap because unguarded RC
  operations now happen on clearly identified paths rather than inside the JIT
  dispatch hot path.

### Concerns

- **[HIGH] LIFE-01: Dual RC systems persist with asymmetric atomicity —
  `src/gene/types/memory.nim`.** `retainManaged` uses `.inc()` (non-atomic
  increment) while `releaseManaged` uses `atomicDec`. On a multi-core system,
  a non-atomic increment concurrent with a decrement from another thread can
  produce a ref-count underflow: the decrement reads a stale count, concludes
  the object is unreachable, and frees it while the incrementing thread still
  holds a live pointer. Classic ABA/torn-count bug. P0.1 was specifically
  designed to collapse the two ownership systems and unify on one atomic
  model. It was not delivered. Any actor that passes an array or map `Value`
  to another thread is exposed to this race today.
- **[HIGH] LIFE-01 corollary: `value_ops.nim` manual `retain`/`release` uses
  `.inc()`/`.dec()` throughout.** The manual path (`retain`, `release` in
  `core/value_ops.nim`) is used on the hot function-call path and uses
  non-atomic integer operations. If a VM running on thread A retains a `Value`
  that thread B is concurrently releasing, the ref count is not protected.
  This is distinct from the `memory.nim` hook asymmetry above — there are two
  independent non-atomic retain paths.
- **[HIGH] BOOT-01: P0.5 not delivered — bootstrap publication boundary
  undefined.** No SUMMARY.md, no implementation, no test file. Without this, a
  module loaded at startup time can have its `body_compiled` pointer read by a
  worker while the main thread is still populating the compilation unit — a
  window that the P0.2 locks do not close, because `publish_compiled_body` is
  only called during lazy compilation, not during bootstrap module loading.
- **[MEDIUM] STR-02 verification gap — `IkPushValue` string literal copy in
  `exec.nim`.** P0.4's SUMMARY.md claims removal of the defensive copy, but
  the reviewer could not verify from context whether the relevant handler in
  `exec.nim` was actually edited. If not removed, STR-02 is undelivered. If
  removed prematurely — before all mutation sites were eliminated — it could
  expose a correctness bug on any codepath that still calls a mutation method.
- **[MEDIUM] `body_publication_lock` scope is too narrow for cross-function
  lazy compilation.** `compiler.nim:631–632` acquires the lock around lazy
  compilation of a single function body. If function A's body compilation
  triggers compilation of a nested closure B (common in Gene), and B is also
  uncompiled, the lock will be re-entered on the same thread. Whether Nim's
  `Lock` is recursive on the target platform is not specified. A non-recursive
  lock here produces a deadlock on first deep closure compilation.
- **[MEDIUM] `load_gir` initializes `inline_caches` outside any lock.**
  `gir.nim:847` sets cache length at parse/load time on the main thread
  without holding `body_publication_lock`. If a worker thread calls
  `publish_compiled_body` for a GIR-loaded function concurrently with a second
  load on the main thread, `inline_caches.setLen` races with
  `ensure_inline_caches_ready` read inside the lock.
- **[LOW] `MtRegisterCallback` message is not acknowledged.** No ACK mechanism.
  Send-after-register is racy. Tolerable for Phase 0, must be addressed before
  ACT-01.
- **[LOW] Global `body_publication_lock` / `native_publication_lock`.** Single
  global lock serializes all concurrent lazy-compilation attempts across all
  functions; lock hold time includes JIT compilation. Performance concern for
  ACT-02.

### Suggestions

1. **Deliver P0.1 before any actor-phase work.** Minimum viable fix: (a) make
   `retainManaged` in `memory.nim` use `atomicInc` to mirror `atomicDec` in
   `releaseManaged`; (b) make `retain`/`release` in `value_ops.nim` use atomic
   operations or a dedicated lock; (c) decide authoritatively which system owns
   compound-type RC and remove or delegate to the other.
2. **Deliver P0.5 with a concrete bootstrap gate.** Simplest implementation is
   a `bootstrap_published: Atomic[bool]` flag (or `Lock`-guarded boolean) set
   by the main thread after module loading completes, and read by each worker
   thread before it begins execution.
3. **Verify STR-02 in `exec.nim`.** Confirm whether the `IkPushValue`
   string-literal defensive copy was removed. If not, remove it and add a test
   that pushes a literal, appends to the result, and confirms the literal is
   unchanged.
4. **Analyze `body_publication_lock` for reentrance.** Check whether Gene's
   closure compilation is recursive w.r.t. `compile()` → `compile_body()` →
   nested closure compilation. If it is, switch to a reentrant lock, or
   compile all nested closures before acquiring the publication lock.
5. **Move `inline_caches.setLen` in `load_gir` inside `body_publication_lock`**
   to close the race between GIR loading and concurrent `publish_compiled_body`.
6. **Add an integration test for concurrent lazy compilation.** Spawn two
   threads that call the same uncompiled Gene function simultaneously and
   assert correctness + no crash. Would have caught the reentrance concern and
   validates P0.2 end-to-end.

### Risk Assessment — HIGH

The delivered work (P0.2, P0.3, P0.4) is correct and meaningfully reduces the
blast radius of multi-threaded bugs in the publication and channel-polling
paths. However, the undelivered P0.1 leaves an unsynchronized retain path on
the type that actors must share — arrays and maps — and the undelivered P0.5
leaves the bootstrap window unguarded. These are not theoretical risks: a Gene
actor that receives a `Value` containing an array will call `retainManaged` on
the receiving thread while the sending thread may still be in `release`, using
non-atomic operations on both sides. This is a live data race under standard
C11 memory model semantics. Proceeding to ACT-01 (actor spawn) with P0.1 and
P0.5 undelivered means the first actor integration tests will exercise the
race conditions these plans were designed to prevent. The bug will likely be
intermittent, timing-dependent, and difficult to reproduce under test — the
worst possible combination for a brownfield codebase. The correct gate:
**P0.1 and P0.5 delivered and tested before any ACT-0x plan is executed.**

---

## Codex Review

### Summary

The five plans are mostly well-shaped against `docs/proposals/actor-design.md`,
but the delivered `actor` branch is only a partial Phase 0 substrate. P0.3 and
P0.4 are materially implemented and regression-covered, P0.2 improves
publication behavior but stops short of the approved concurrency model, and
P0.1 plus P0.5 are still undelivered, so this branch is not yet the safe
foundation that ACT-01..04 can build on.

### Strengths

- The plan set mirrors the approved Phase 0 split cleanly: RC, publication,
  thread runtime, string cut, then bootstrap sweep.
- P0.3 is directionally correct and tested: reply polling now uses the caller
  thread slot in `src/gene/vm/async_exec.nim:147-151`, and target-thread
  callback registration is routed through a control message in
  `src/gene/vm/thread_native.nim:371-381`.
- P0.4 is coherent: `String.append` returns a new value in both string
  surfaces (`src/gene/stdlib/strings.nim:27-47`,
  `src/gene/stdlib/core.nim:508-528`), and `IkPushValue` no longer clones
  string literals (`src/gene/vm/exec.nim:1518-1519`).
- The landed slices have real execution evidence. Reviewer compiled and ran
  `tests/integration/test_scope_lifetime.nim`,
  `tests/integration/test_thread.nim`,
  `tests/integration/test_stdlib_string.nim`,
  `tests/test_native_trampoline.nim`, and
  `tests/integration/test_cli_gir.nim`; all passed.

### Concerns

- **[HIGH] Phase 0 is not actually delivered.** P0.1 and P0.5 have no
  `SUMMARY.md`, `tests/test_bootstrap_publication.nim` does not exist, and the
  branch diff contains no changes to `src/gene/types/core/value_ops.nim`,
  `src/gene/types/memory.nim`, `src/gene/types/core/frames.nim`,
  `src/gene/native/trampoline.nim`, or
  `tests/integration/test_scope_lifetime.nim`. That leaves LIFE-01 and BOOT-01
  open.
- **[HIGH] PUB-02 is only partially satisfied.** The design requires per-worker
  caches or atomic cache-slot writes
  (`docs/proposals/actor-design.md:431-445`), but the runtime still mutates
  shared cache slots with plain writes in `src/gene/vm/exec.nim:555-579`.
  Pre-sizing `inline_caches` removes the `setLen` race, but not the
  shared-slot race.
- **[HIGH] `body_compiled` and native publication still do not implement the
  approved read-side synchronization.** Writers are serialized with global
  locks in `src/gene/compiler.nim:630-714`, `src/gene/types/helpers.nim:11-42`,
  and `src/gene/vm/native.nim:98-117`, but readers still do plain
  unsynchronized checks and then use the published pointer in
  `src/gene/vm/exec.nim:4728-4766` and `src/gene/vm/native.nim:98-123`. That
  prevents duplicate compilation, but it is not the release/acquire-or-eager-
  init invariant the proposal calls for.
- **[HIGH] BOOT-01 is absent in code, not just process.** `Application` has
  live namespace fields but no `bootstrap_frozen` or snapshot state in
  `src/gene/types/type_defs.nim:380-420`; `init_app_and_vm` and helper setters
  mutate shared namespaces directly in `src/gene/types/helpers.nim:124-255`;
  and module/extension loading mutates them again at runtime in
  `src/gene/vm/module.nim:927-959` and `src/gene/vm/module.nim:1241-1264`.
  Incompatible with the "freeze after init" boundary.
- **[MEDIUM] Closing plan is not fully sound as written.** `00-05-PLAN.md:6-9`
  does not depend on `00-01`, and its acceptance sweep in
  `00-05-PLAN.md:101-121` omits `tests/integration/test_scope_lifetime.nim`, so
  Phase 0 could have been declared complete without re-verifying LIFE-01.
- **[MEDIUM] The `.on_message` fix is safe but narrowed.** Remote registration
  requires `VkNativeFn` in `src/gene/vm/thread_native.nim:365-381`, and the new
  regression only covers that path in `tests/integration/test_thread.nim:259-281`.
  Sensible temporary restriction, but later actor work still lacks a
  thread-safe cross-worker callable model.
- **[LOW] Branch is broader than the Phase 0 plans.** Also changes
  module/local-def and advice resolution semantics in
  `src/gene/compiler/control_flow.nim:745-760`,
  `src/gene/compiler/functions.nim:219-230,463-482`,
  `src/gene/stdlib/aspects.nim:41-65`, and `src/gene/vm/exec.nim:3418-3435`.
  Those changes may be valid, but they increase risk and make this less of a
  clean substrate branch.

### Suggestions

- Finish P0.1 before claiming Phase 0 readiness: land the ownership unification
  in `memory.nim`/`value_ops.nim`, add the planned lifetime regressions, and
  stop making ad hoc lifetime adjustments in VM hot paths without that
  canonical model.
- Rework P0.2 to match the approved design exactly: either move inline caches
  to per-worker state or make cache-slot updates atomic, and make
  `body_compiled`/`native_ready` use a real acquire/read path rather than only
  a writer lock.
- Implement P0.5 explicitly: add `bootstrap_frozen` or equivalent snapshot
  state, create `tests/test_bootstrap_publication.nim`, and guard post-init
  mutation of the five approved shared targets.
- Update `00-05-PLAN.md` so it depends on `00-01` and includes
  `tests/integration/test_scope_lifetime.nim` in the acceptance sweep.
- Document the temporary `VkNativeFn`-only remote callback rule as an explicit
  interim limitation for later actor phases.
- Split the extra module/local-def/AOP fixes into a separate review stream or
  commit so Phase 0 substrate work can be evaluated on its own merits.

### Risk Assessment — HIGH

The landed pieces are not obviously broken and the targeted tests pass, but
the branch still misses two of the five Phase 0 deliverables, lacks the
bootstrap boundary the proposal requires, and leaves the key publication paths
short of the approved concurrency semantics. That makes it useful incremental
groundwork, not yet a safe actor-runtime substrate.

---

## Consensus Summary

### Agreed Strengths (both reviewers)

- **P0.3 thread-runtime fixes are directionally correct and regression-tested.**
  `async_exec.nim` now polls `current_thread_id` instead of thread 0;
  `.on_message` uses a dedicated `MtRegisterCallback` control message with the
  safe `VkNativeFn`-only restriction for remote registration.
- **P0.4 string immutability is coherent** across both stdlib surfaces
  (`strings.nim`, `core.nim`); alias-safety is pinned by integration tests.
- **The plan set mirrors the approved proposal's Phase 0 split cleanly.**
- **Landed slices pass the targeted regression suites** (Codex executed them).

### Agreed Concerns (both reviewers, HIGH priority)

1. **P0.1 (LIFE-01) is undelivered.** No changes to `value_ops.nim` /
   `memory.nim` / frames / trampoline; no new lifetime tests. Claude adds the
   specific mechanism: `retainManaged` non-atomic `.inc()` vs `releaseManaged`
   `atomicDec` — a live C11 data race on any `Value` shared across threads
   (arrays, maps).
2. **P0.5 (BOOT-01) is undelivered.** No `bootstrap_frozen` state, no
   `tests/test_bootstrap_publication.nim`, and runtime-time namespace mutation
   in `module.nim` is still unguarded.
3. **Publication safety is incomplete even where landed.** Codex adds nuance:
   writer-side locks in P0.2 do not implement the release/acquire (or
   eager-init) invariant the proposal specifies on the *reader* side. Claude
   flags the same gap via `load_gir` initializing caches outside any lock.

### Divergent Views

- **Is P0.2 "done"?** Claude calls the double-checked locking in
  `prepare_native_ctx` correct and PUB-01/02/03 satisfied. Codex disagrees:
  readers are still unsynchronized and shared cache slots are still racy. The
  tension is between "writer lock is sufficient in practice on current
  platforms" (Claude) and "the proposal requires the full invariant, not a
  subset" (Codex). Codex's stricter reading matches the design doc literally;
  Claude's reading matches what the code actually implements.
- **Branch scope.** Only Codex flags that the `actor` branch also modifies
  compiler/AOP semantics unrelated to Phase 0 substrate work (local-def
  compilation in `control_flow.nim` / `functions.nim`, aspect resolution in
  `aspects.nim` / `exec.nim`). Worth confirming before merge.

### Recommended Gates Before Merging / Proceeding to Actor Phases

1. Deliver **P0.1** (atomic-unified `retain`/`release`, LIFE-01 regressions)
   **before** any ACT-0x plan runs.
2. Deliver **P0.5** (`bootstrap_frozen` gate,
   `tests/test_bootstrap_publication.nim`, module/extension loading under the
   guard).
3. Either tighten **P0.2**'s reader path to release/acquire / atomic cache
   slots, or add an explicit note in `00-02-SUMMARY.md` scoping PUB-* to
   "writer lock only, reader-side deferred" so the gap is tracked.
4. Add `depends_on: ["00-01"]` to **`00-05-PLAN.md`** and include
   `tests/integration/test_scope_lifetime.nim` in its acceptance sweep.
5. **Separate the non-Phase-0 compiler/AOP changes** from the substrate branch
   so reviewers can evaluate each slice on its own.
6. Add a **concurrent lazy-compilation integration test** (Claude's
   suggestion) that exercises two threads calling the same uncompiled Gene
   function simultaneously — validates P0.2 and surfaces the
   `body_publication_lock` reentrance question.

### Consensus Risk: HIGH

Both reviewers independently converge on HIGH risk with the same primary
cause: the `actor` branch is labelled "Actor support" and contains real
publication / thread-runtime improvements, but the two workstreams that
actually govern ref-count safety (P0.1) and bootstrap visibility (P0.5) are
not present in code. Those are prerequisites, not nice-to-haves, for ACT-01.

---

To incorporate this feedback into planning, re-run:

    /gsd-plan-phase 0 --reviews
