# Phase 04: Remove Legacy Thread-First Concurrency Surfaces - Research

**Researched:** 2026-04-22  
**Domain:** public concurrency API removal, worker naming cleanup, migration boundary finalization  
**Confidence:** MEDIUM

## User Constraints

- Phase 03 is complete; extension-side concurrency ownership already moved behind actor/port boundaries. [VERIFIED: `.planning/ROADMAP.md`, `.planning/phases/03-port-actors-for-extensions/03-VERIFICATION.md`]
- Actors are now the recommended concurrency API. Thread-first surfaces remain only as compatibility debt. [VERIFIED: `docs/handbook/actors.md`, `docs/thread_support.md`]
- The internal worker substrate still underpins the actor runtime, so Phase 04 must remove the **public** thread-first API without tearing out the worker implementation actors still use. [VERIFIED: `src/gene/vm/actor.nim`, `src/gene/vm/thread_native.nim`]

## Requirement

| ID | Description | Research Support |
|----|-------------|------------------|
| ACT-04 | Deprecate/remove the legacy thread API after the actor API is verified. | This research maps the remaining public/compiler/docs surfaces and separates them from the internal worker substrate that actors still depend on. |

## Summary

Phase 04 is not “delete threading from the runtime.” It is “remove the thread-first **public** surface.”

The remaining public/compiler-facing surfaces are:

- compiler spellings:
  - `spawn`
  - `spawn_return`
  - `send_expect_reply`
  - `keep_alive`
  (`src/gene/compiler/async.nim`, `src/gene/compiler/operators.nim`, `src/gene/stdlib/core.nim`) [VERIFIED]
- public thread classes and methods:
  - `Thread`
  - `ThreadMessage`
  - `Thread.send`
  - `Thread.send_expect_reply`
  - `Thread.on_message`
  (`src/gene/vm/thread_native.nim`, `src/gene/vm/thread.nim`) [VERIFIED]
- thread-local public handles:
  - `$thread`, `thread`
  - `$main_thread`, `main_thread`
  (`src/gene/vm/runtime_helpers.nim`, `src/gene/types/helpers.nim`) [VERIFIED]
- worker configuration naming:
  - `GENE_MAX_THREADS`
  - proposal target: `GENE_WORKERS`
  (`src/gene/types/core.nim`, `docs/proposals/actor-design.md:560`, `docs/proposals/actor-design.md:753`) [VERIFIED]

The internal substrate that should **remain** is:

- thread pool slot management
- per-worker channels
- worker-thread VM bootstrap
- actor worker runtime built on top of that substrate

(`src/gene/vm/thread_native.nim`, `src/gene/vm/runtime_helpers.nim`, `src/gene/vm/actor.nim`) [VERIFIED]

## Primary Recommendation

Split Phase 04 into three plans:

1. remove/deprecate the public thread-first language/runtime surface
2. rename worker-facing configuration/docs/examples from `GENE_MAX_THREADS` to `GENE_WORKERS`, keeping only the internal substrate
3. run the migration verification sweep and close the phase

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Public API removal | compiler + stdlib namespace + thread classes | docs/tests | Thread-first entrypoints are scattered across compiler sugar and namespace registration. |
| Worker naming cleanup | runtime config + docs/examples | tests | `GENE_MAX_THREADS` is public-facing naming debt even if the internal worker pool remains. |
| Internal substrate preservation | actor runtime + thread worker internals | none | Actors still depend on worker threads internally; Phase 04 removes the public lane, not the worker machinery. |

## Likely Migration Targets

| Surface | Current Problem | Phase 04 Outcome |
|--------|-----------------|------------------|
| `spawn` / `spawn_return` | thread-first compiler surface still public | remove or turn into explicit migration errors pointing at actors |
| `Thread` / `ThreadMessage` classes | public thread-first runtime surface still exported | remove from public namespace/class bootstrap or leave only explicit unsupported shims |
| `send_expect_reply`, `keep_alive` globals | top-level thread compatibility helpers still public | remove from public namespace or replace with migration errors |
| `$thread`, `$main_thread` | thread-first convenience handles still public | assess whether they remain needed for internal/runtime use only; remove from user-visible docs and surface if possible |
| `GENE_MAX_THREADS` | thread-first naming | rename to `GENE_WORKERS`, decide whether to keep a compatibility alias temporarily |

## Anti-Patterns

- deleting the worker substrate actors still use
- mixing Phase 04 public-surface removal with new actor features
- keeping thread-first compiler sugar alive “just in case”
- renaming docs/examples without changing runtime naming, or vice versa
