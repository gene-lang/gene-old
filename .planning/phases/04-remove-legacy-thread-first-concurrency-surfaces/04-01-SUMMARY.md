---
phase: 04-remove-legacy-thread-first-concurrency-surfaces
plan: 01
subsystem: compiler-runtime
tags: [nim, compiler, runtime, actors, cleanup]
requires:
  - phase: 03
    provides: Actor-first runtime and extension ownership model
provides:
  - Public thread-first compiler spellings removed
  - Public thread runtime entrypoints no longer exported
  - Negative integration coverage that locks the removed-surface contract
affects: [04-02, 04-03, compiler, runtime]
key-files:
  modified:
    - src/gene/compiler.nim
    - src/gene/compiler/async.nim
    - src/gene/compiler/operators.nim
    - src/gene/vm/thread.nim
    - src/gene/vm/thread_native.nim
    - src/gene/stdlib/core.nim
    - src/gene/vm/runtime_helpers.nim
    - src/gene/types/helpers.nim
    - src/gene/vm/actor.nim
    - tests/integration/test_thread.nim
    - tests/integration/test_actor_runtime.nim
completed: 2026-04-22T00:00:00Z
---

# Phase 4 Plan 1 Summary

**The public thread-first language/runtime surface is gone; the internal worker substrate remains only as an actor implementation detail**

## Accomplishments

- Removed compiler handling for `spawn` / `spawn_return` so they are no longer a language-level concurrency surface.
- Stopped publishing `Thread`, `ThreadMessage`, `send_expect_reply`, and `keep_alive` as public runtime entrypoints.
- Removed `$thread` / `$main_thread` from the runtime-local namespace bootstrap.
- Preserved the worker/channel substrate and actor worker scheduling internals so actors still run correctly.
- Replaced the old positive thread integration suite with negative coverage that locks the removed-surface contract.

## Verification

- `nim c -r tests/integration/test_thread.nim`
- `nim c -r tests/integration/test_actor_runtime.nim`
- `nim c -r tests/integration/test_actor_reply_futures.nim`

## Follow-up for 04-02

- Remove the remaining active docs/example references to the retired thread-first surface.
- Finish the public worker naming cleanup to `GENE_WORKERS`.
