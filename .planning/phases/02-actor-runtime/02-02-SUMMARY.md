---
phase: 02-actor-runtime
plan: 02
subsystem: runtime
tags: [nim, actors, worker-pool, stdlib, integration-testing]
requires:
  - phase: 02-01
    provides: Actor and ActorContext runtime kinds plus VM class slots
provides:
  - gene/actor enable and spawn entrypoints
  - actor worker bootstrap on the existing thread substrate
  - Actor and ActorContext runtime methods for send, reply, and stop
  - integration coverage for enable-before-spawn, state threading, and thread compatibility
affects: [02-03, actor-api, scheduler, thread-compatibility]
tech-stack:
  added: []
  patterns:
    - actor workers reuse existing thread slots, channels, and future reply polling
    - actor API stays namespaced under gene/actor while bare spawn remains thread-only
key-files:
  created:
    - src/gene/vm/actor.nim
    - src/gene/stdlib/actor.nim
  modified:
    - src/gene/stdlib/core.nim
    - src/gene/vm.nim
    - tests/integration/test_actor_runtime.nim
decisions:
  - "Expose actor bootstrap only through gene/actor/* and leave bare spawn on the legacy thread path."
  - "Pin actors onto bounded workers taken from the existing thread pool instead of building a second concurrency runtime."
  - "Default gene/actor/enable worker count to CPU-count-bounded pool usage so actor startup does not starve the thread compatibility lane."
metrics:
  duration: 14 min
  completed: 2026-04-20T14:53:10Z
  tasks: 2
  files: 5
---

# Phase 2 Plan 2: Actor Bootstrap on the Existing Worker Substrate

**Actors now boot explicitly through `gene/actor/*`, execute one message at a time on reused thread-worker slots, and leave the legacy `spawn` thread behavior intact.**

## Accomplishments

- Added `src/gene/vm/actor.nim` as the actor runtime substrate. It enables a bounded worker set from the existing thread pool, pins actors to those workers, routes actor sends through the existing thread channels, and resolves replies through the existing `thread_futures` / `MtReply` path.
- Added `src/gene/stdlib/actor.nim` plus stdlib bootstrap wiring so `gene/actor/enable` and `gene/actor/spawn` are registered under the `gene` namespace without introducing bare actor aliases.
- Added `Actor` and `ActorContext` runtime methods for `send`, `send_expect_reply`, `reply`, `actor`, and `stop`.
- Replaced the RED harness with a passing integration gate that proves three things in one execution path: spawn is rejected before enable, actor state advances sequentially, and bare `spawn` still behaves as the thread API.

## Task Commits

1. **Task 1: Lock the actor bootstrap contract in an integration harness** - `a74fdfa` (`test`)
2. **Task 2: Implement actor enable/spawn bootstrap and namespace wiring** - `45949f0` (`feat`)

## Files Created/Modified

- `src/gene/vm/actor.nim` - actor worker bootstrap, registry/state, actor send/reply flow, and class initialization.
- `src/gene/stdlib/actor.nim` - `gene/actor` namespace registration.
- `src/gene/stdlib/core.nim` - actor runtime reset/bootstrap wiring into stdlib initialization.
- `src/gene/vm.nim` - actor runtime module import.
- `tests/integration/test_actor_runtime.nim` - integration proof for enable-before-spawn, sequential actor state progression, and preserved thread spawn behavior.

## Verification

- `nim c -r tests/integration/test_actor_runtime.nim`
- `nim c -r tests/integration/test_thread.nim`

## Decisions Made

- The actor bootstrap surface stays namespaced under `gene/actor/*`; the compiler-owned bare `spawn` path remains thread-only.
- Actor workers reuse `get_free_thread`, `init_thread`, `THREAD_DATA[...]`, and the existing `MtReply` / `thread_futures` pipeline rather than introducing a second mailbox transport.
- `gene/actor/enable` defaults to a CPU-count-bounded worker count instead of consuming the full configured pool so legacy thread spawning still has capacity after actor bootstrap.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The first version of the integration harness reinitialized the whole runtime between separate tests after actor workers had started. Consolidating the assertions into one end-to-end test avoided teardown races while keeping the required plan coverage intact.

## Known Stubs

None.

## Threat Flags

None.

## Self-Check: PASSED

- Verified `.planning/phases/02-actor-runtime/02-02-SUMMARY.md` exists on disk.
- Verified task commits `a74fdfa` and `45949f0` exist in git history.
