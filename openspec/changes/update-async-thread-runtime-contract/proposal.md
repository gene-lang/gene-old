# Proposal: Unify Async + Thread Runtime Contract

## Why

Gene currently has overlapping runtime paths for futures, callbacks, async polling, and thread reply futures. The behavior is functional but not fully deterministic:
- callback execution exists in more than one path (`vm/async.nim` and `vm/async_exec.nim`),
- thread reply futures and Nim-backed futures use adjacent but different completion flows,
- timeout/cancel semantics are not specified as first-class runtime contract,
- ownership of polling and callback dispatch is not specified as a single authority.

This creates ambiguity for users and raises risk of edge-case regressions (double-callback, silent pending futures, inconsistent failure propagation).

## What Changes

- Define one runtime contract for all futures (Nim async, thread reply, and manually completed futures).
- Add explicit terminal lifecycle state for cancellation and specify legal state transitions.
- Define single-owner polling + dispatch rules (one scheduler authority in VM runtime).
- Define deterministic callback semantics (ordering, once-only execution, late-registration behavior).
- Add timeout and cancellation semantics for `await` and thread request/reply futures.
- Add conformance tests as release gate for async/thread contract behavior.

### **BREAKING**

- Unmatched/abandoned pending futures at timeout now fail deterministically with typed runtime exceptions instead of remaining implicitly pending.
- Cancelled futures become terminal and cannot later transition to success/failure.
- Callback dispatch timing is normalized to scheduler-driven execution, removing ad-hoc path differences.

## Impact

- Affected specs: `async`, `threading`
- Affected code:
  - `src/gene/types/type_defs.nim` (future lifecycle state)
  - `src/gene/vm/async.nim` (Future API behavior)
  - `src/gene/vm/async_exec.nim` (poll/dispatch authority)
  - `src/gene/vm/exec.nim` (await semantics)
  - `src/gene/vm/thread.nim` (thread future completion/cancel/timeout integration)
  - `src/gene/stdlib/core.nim` (scheduler loop interface where applicable)
  - tests for async/thread/future behavior

- Risk profile: medium (cross-cutting runtime behavior change)
- Mitigation:
  - explicit state-transition checks,
  - strict conformance tests,
  - staged rollout behind one implementation change set.
