# Phase 02: Actor Runtime - Research

**Researched:** 2026-04-20  
**Domain:** Gene actor runtime over the existing thread, future, and freeze substrate  
**Confidence:** MEDIUM

<user_constraints>
## User Constraints (from CONTEXT.md)

No Phase 2 `*-CONTEXT.md` exists, so the effective constraints are the user prompt plus `.planning/ROADMAP.md`, `.planning/REQUIREMENTS.md`, `.planning/STATE.md`, `.planning/PROJECT.md`, `docs/proposals/actor-design.md`, `docs/proposals/future/actor_support.md`, `docs/thread_support.md`, and the completed Phase 1 / 1.5 summaries. [VERIFIED: codebase grep]

### Locked Decisions
- Phase 2 must deliver actor scheduling, tiered send behavior, reply futures, stop semantics, and a user-facing actor API on top of the completed Phase 1.5 substrate. [VERIFIED: .planning/ROADMAP.md; .planning/REQUIREMENTS.md]
- Phase 1.5 closure freezeability is complete and is the direct prerequisite Phase 2 must consume instead of re-solving closure sendability in transport code. [VERIFIED: .planning/ROADMAP.md; .planning/phases/01.5-freezable-closures/01.5-01-SUMMARY.md; .planning/phases/01.5-freezable-closures/01.5-02-SUMMARY.md]
- Legacy thread-first surfaces stay temporarily for compatibility; their retirement belongs to Phase 4, not Phase 2. [VERIFIED: .planning/ROADMAP.md; docs/handbook/freeze.md]

### Claude's Discretion
- Decompose Phase 2 into executable waves/plans, identify exact runtime files likely to change, recommend how to consume the Phase 1.5 closure-freeze contract, and define a verification strategy for scheduling, send tiers, reply futures, and stop semantics. [VERIFIED: user prompt]

### Deferred Ideas (OUT OF SCOPE)
- Port-actor migration for extensions belongs to Phase 3. [VERIFIED: .planning/ROADMAP.md; .planning/PROJECT.md]
- Thread API deprecation/removal and `GENE_WORKERS` rename belong to Phase 4. [VERIFIED: .planning/ROADMAP.md; .planning/PROJECT.md]
- Work-stealing and `send!` stay deferred beyond the MVP actor runtime. [CITED: docs/proposals/actor-design.md]
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ACT-02 | Add actor scheduler, tiered send, reply futures, and actor stop semantics. [VERIFIED: .planning/REQUIREMENTS.md] | This research maps the existing worker/channel/future substrate, identifies the exact files that must change, recommends a four-wave implementation order, shows how Phase 1.5 frozen closures plug into send tiers, and defines the missing tests required to verify scheduling, send behavior, reply futures, and stop semantics. [VERIFIED: codebase grep] |

</phase_requirements>

## Summary

Phase 2 should be planned as an overlay on top of the runtime that already exists, not as a second concurrency runtime. The codebase already has a worker pool and mailbox substrate in `src/gene/vm/thread_native.nim`, worker bootstrap and per-thread VM setup in `src/gene/vm/runtime_helpers.nim`, reply/future completion in `src/gene/vm/async_exec.nim`, and the `deep_frozen` / `shared` contract plus closure-freeze handoff from Phase 1 / 1.5 in `src/gene/stdlib/freeze.nim`, `src/gene/types/core/value_ops.nim`, and `docs/handbook/freeze.md`. [VERIFIED: codebase grep]

The critical planning move is to separate "reuse the substrate" from "preserve the old user surface." Phase 2 should reuse the current worker bootstrap, polling loop, `FutureObj`, and channel implementation, but it should not repurpose the legacy thread API as the public actor API because `spawn` is already a compiler special form for threads and the roadmap explicitly keeps thread compatibility until Phase 4. The least risky Phase 2 public surface is `gene/actor/*` plus an `Actor` handle and `ActorContext`, while `spawn`, `spawn_return`, `Thread.send`, `Thread.send_expect_reply`, `Thread.on_message`, `keep_alive`, and `GENE_MAX_THREADS` remain operational compatibility surfaces. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/exec.nim; docs/handbook/freeze.md; .planning/ROADMAP.md] [CITED: docs/proposals/future/actor_support.md] [ASSUMED]

Three design conflicts still need to be locked before execution because they change both the implementation plan and the test matrix: actor API naming (`gene/actor/spawn` versus bare `spawn`), mailbox-full behavior (blocking sender versus non-blocking backpressure / parked sender), and handler-exception policy (actor continues versus actor dies). The approved `actor-design.md` document supersedes the older `future/actor_support.md`, but it leaves these items as open questions while the older proposal resolves them differently, so the planner should treat them as explicit decisions rather than silently inheriting one side. [VERIFIED: docs/proposals/actor-design.md; docs/proposals/future/actor_support.md]

**Primary recommendation:** Plan Phase 2 as four waves: `actor substrate and API`, `tiered send`, `reply futures and stop semantics`, and `compatibility/docs/verification`; keep the legacy thread API untouched, expose the new actor API under `gene/actor/*`, and consume Phase 1.5 closure freezeability strictly through `deep_frozen/shared` checks rather than serializer changes. [VERIFIED: codebase grep] [CITED: docs/proposals/actor-design.md] [ASSUMED]

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Actor handle / context / runtime types | Runtime type system | Stdlib surface | New handle kinds must live in `ValueKind`, `Reference`, class resolution, and native converters before the stdlib can expose them. [VERIFIED: src/gene/types/type_defs.nim; src/gene/types/reference_types.nim; src/gene/types/core/native_helpers.nim; src/gene/vm/core_helpers.nim] |
| Actor enable / spawn / send / stop public API | Stdlib / native API surface | Runtime worker substrate | The user-facing API should be registered in the Gene namespace or a `gene/actor` namespace, while execution still lands on the worker/mailbox substrate. [VERIFIED: src/gene/stdlib/core.nim; src/gene/vm/thread_native.nim] [CITED: docs/proposals/future/actor_support.md] |
| Scheduler and mailbox dispatch | VM runtime | Thread substrate | The scheduler loop belongs beside worker bootstrap and mailbox receive logic, and should reuse the existing pool/channel infrastructure rather than create a second pool. [VERIFIED: src/gene/vm/thread_native.nim; src/gene/vm/runtime_helpers.nim] [CITED: docs/proposals/actor-design.md] |
| Tiered send (primitive / frozen / mutable) | Runtime memory + actor transport | Freeze substrate | Send-tier routing depends on `deep_frozen/shared`, the shared-RC invariant, and the Phase 1.5 frozen-closure rule. [VERIFIED: src/gene/types/memory.nim; src/gene/types/core/value_ops.nim; src/gene/stdlib/freeze.nim; docs/handbook/freeze.md] [CITED: docs/proposals/actor-design.md] |
| Reply futures | Existing future runtime | Actor transport | `FutureObj`, `await`, and `poll_event_loop` already exist; Phase 2 should add actor-specific reply tracking instead of inventing a second awaitable surface. [VERIFIED: src/gene/types/core/futures.nim; src/gene/vm/async.nim; src/gene/vm/async_exec.nim] |
| Stop semantics and cleanup | Actor runtime | Future runtime | Stop behavior must change actor lifecycle state, reject later sends, drop queued mail, and fail outstanding reply futures. [CITED: docs/proposals/future/actor_support.md] [ASSUMED] |
| Legacy thread compatibility | Existing thread runtime | Docs / tests | Thread surfaces stay alive through Phase 2, so compatibility is mainly about not regressing existing code and tests. [VERIFIED: docs/handbook/freeze.md; docs/thread_support.md; tests/integration/test_thread.nim] |
| Extension scheduler compatibility | Existing scheduler loop | Actor runtime | `run_forever` and host scheduler callbacks are already used by HTTP and AI extensions and must keep working while actors are added. [VERIFIED: src/gene/stdlib/core.nim; src/gene/types/memory.nim; src/gene/vm/extension.nim; src/genex/http.nim; src/genex/ai/bindings.nim] |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Nim compiler / stdlib | Local toolchain `2.2.4`; current Nim stable is `2.2.8`. [VERIFIED: `nim --version`] [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html] | Build, threads, atomics, async dispatcher, and unittest support. [VERIFIED: codebase grep] | The repo already compiles and tests the runtime with Nim 2.2.4, and all concurrency primitives in this phase are standard-library or project-native code. [VERIFIED: gene.nimble; codebase grep] |
| Existing worker/channel substrate | Workspace HEAD. [VERIFIED: codebase grep] | OS-thread pool, shared channel implementation, worker bootstrap, and thread-local VM setup. [VERIFIED: src/gene/vm/thread_native.nim; src/gene/vm/runtime_helpers.nim] | Reusing this substrate keeps compatibility risk lower than creating a second worker system. [VERIFIED: codebase grep] [CITED: docs/proposals/actor-design.md] |
| Existing future substrate | Workspace HEAD. [VERIFIED: codebase grep] | `FutureObj`, `await`, callback scheduling, and reply completion. [VERIFIED: src/gene/types/core/futures.nim; src/gene/vm/async.nim; src/gene/vm/async_exec.nim] | Reply futures are already a first-class runtime concept, so Phase 2 should extend them rather than duplicate them. [VERIFIED: codebase grep] |
| Phase 1 / 1.5 freeze substrate | Workspace HEAD. [VERIFIED: codebase grep] | `deep_frozen`, `shared`, `(freeze v)`, and freezable closures. [VERIFIED: src/gene/stdlib/freeze.nim; src/gene/types/core/value_ops.nim; docs/handbook/freeze.md] | Tiered send depends directly on this contract, especially the completed Phase 1.5 closure-freeze rule. [VERIFIED: .planning/phases/01.5-freezable-closures/01.5-02-SUMMARY.md; docs/handbook/freeze.md] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `std/typedthreads` | Nim stable docs generated 2026-02-23. [CITED: https://nim-lang.org/docs/typedthreads.html] | Official `createThread` / `joinThread` / thread-memory model reference. [CITED: https://nim-lang.org/docs/typedthreads.html] | Use as the language-level contract for the worker-pool implementation that Gene already wraps. [VERIFIED: src/gene/vm/runtime_helpers.nim] |
| `std/atomics` | Nim stable docs generated 2026-02-23. [CITED: https://nim-lang.org/docs/atomics.html] | Atomic state transitions, counters, and mailbox-ready tracking. [CITED: https://nim-lang.org/docs/atomics.html] | Use for actor lifecycle state, ready-queue coordination, and mailbox counters; the repo already uses `Atomic[int]` in `src/genex/http.nim`. [VERIFIED: src/genex/http.nim] |
| `std/asyncdispatch` / `std/asyncfutures` | Nim stable docs generated 2026-02-23. [CITED: https://nim-lang.org/docs/asyncdispatch.html] [CITED: https://nim-lang.org/docs/asyncfutures.html] | Event-loop polling and callback semantics for underlying Nim futures. [CITED: https://nim-lang.org/docs/asyncdispatch.html] [CITED: https://nim-lang.org/docs/asyncfutures.html] | Use as the underlying host loop and callback model that the existing Gene future runtime already wraps. [VERIFIED: src/gene/vm/async_exec.nim; src/gene/vm/async.nim] |
| `run_forever` scheduler callbacks | Workspace HEAD. [VERIFIED: codebase grep] | Extension poll integration for HTTP / AI runtime lanes. [VERIFIED: src/gene/stdlib/core.nim; src/gene/types/memory.nim] | Keep this loop intact while adding actors; Phase 2 should not fork the process-level scheduler story. [VERIFIED: src/gene/vm/extension.nim; src/genex/http.nim; src/genex/ai/bindings.nim] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Reusing the current worker/channel substrate | A second actor-only worker pool | Rejected because it duplicates lifecycle, bootstrap, shutdown, and testing surfaces that already exist in `thread_native.nim` / `runtime_helpers.nim`. [VERIFIED: codebase grep] [ASSUMED] |
| Namespaced actor API (`gene/actor/*`) | Rebinding bare `spawn` as actors in Phase 2 | Rejected for the MVP because `spawn` already compiles to `IkSpawnThread`, thread compatibility is explicitly retained until Phase 4, and overloading the same spelling would blur migration boundaries. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/exec.nim; docs/handbook/freeze.md; .planning/ROADMAP.md] [ASSUMED] |
| Tiered send using `deep_frozen/shared` | Extending `serialize_literal` for actors | Rejected because the approved actor design explicitly replaces serializer-based transport for actor sends, and Phase 1.5 already fenced thread serialization as a legacy boundary. [VERIFIED: src/gene/vm/thread_native.nim; src/gene/serdes.nim; docs/handbook/freeze.md] [CITED: docs/proposals/actor-design.md] |

**Installation:**
```bash
# No new dependencies recommended for Phase 2.
# Use the existing Nim toolchain and workspace runtime.
```

**Version verification:** The repo requires `nim >= 2.0.0` in `gene.nimble`, the local machine has Nim `2.2.4`, and current Nim stable is `2.2.8`. [VERIFIED: gene.nimble; `nim --version`] [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html]

## Architecture Patterns

### System Architecture Diagram

```text
gene/actor/enable
  -> initialize actor registry + worker ownership
  -> reuse existing thread pool bootstrap

gene/actor/spawn(handler, state)
  -> validate actor runtime enabled
  -> validate handler is callable and actor-safe
  -> allocate Actor record + mailbox
  -> pin actor to worker
  -> enqueue Actor in ready queue

actor.send / actor.send_expect_reply
  -> classify payload
     -> primitive: enqueue by value
     -> deep_frozen/shared: retain + enqueue pointer
     -> mutable: deep-clone mutable spine, pointer-share frozen subgraphs
  -> optional reply slot / FutureObj registration
  -> worker wakes pinned actor

worker scheduler loop
  -> pop ready actor
  -> CAS Ready -> Running
  -> pop one mailbox message
  -> invoke handler(ctx, msg, state)
  -> update state / resolve reply / mark stop
  -> Running -> Ready or Waiting or Stopped

await / run_forever / poll_event_loop
  -> drain actor replies and ordinary async futures
  -> preserve extension scheduler callbacks
```

The planner should treat the actor scheduler as a VM/runtime concern layered on top of the existing worker substrate, not as a compiler feature. The compiler already reserves bare `spawn` for `IkSpawnThread`, so the actor surface is better added as native functions/classes. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/exec.nim] [ASSUMED]

### Recommended Project Structure

```text
src/gene/
├── stdlib/core.nim                # actor namespace hookup if no dedicated stdlib/actor module is added
├── stdlib/actor.nim               # recommended new actor API module [ASSUMED]
├── types/type_defs.nim            # Actor/ActorContext kinds, runtime records, class slots
├── types/reference_types.nim      # storage for new reference kinds
├── types/core/native_helpers.nim  # converters for Actor / ActorContext handles
├── types/runtime_types.nim        # runtime type names for new kinds
├── vm/core_helpers.nim            # class resolution for Actor / ActorContext
├── vm/thread_native.nim           # reuse Channel + worker slots; preserve Thread API compatibility
├── vm/runtime_helpers.nim         # worker bootstrap and scheduler loop entry
├── vm/async.nim                   # FutureObj reuse for actor replies
├── vm/async_exec.nim              # actor reply polling and callback execution
└── vm.nim                         # import/include wiring for any new actor module
tests/
├── test_phase2_actor_send_tiers.nim         # new unit coverage for primitive / frozen / mutable send behavior
├── integration/test_actor_runtime.nim       # new end-to-end spawn / schedule / state progression coverage
├── integration/test_actor_reply_futures.nim # new reply / failure / timeout coverage
├── integration/test_actor_stop_semantics.nim# new stop / drop / reject-send coverage
└── testsuite/10-async/actors/              # recommended new Gene-level actor semantics suite [ASSUMED]
```

### Likely File Touch Points

| File | Why It Changes | Phase 2 Scope |
|------|----------------|---------------|
| `src/gene/types/type_defs.nim` | Current concurrency kinds stop at `VkFuture`, `VkThread`, and `VkThreadMessage`, and `Application` only has class slots for those surfaces. [VERIFIED: src/gene/types/type_defs.nim:172-175; src/gene/types/type_defs.nim:382-445] | Add `VkActor` / `VkActorContext` (and any actor message/state enums/records), plus app-level class slots and possibly actor-runtime bookkeeping. [ASSUMED] |
| `src/gene/types/reference_types.nim` | `Reference` currently stores `future`, `thread`, and `thread_message`, but no actor handle/context payloads. [VERIFIED: src/gene/types/reference_types.nim:126-133] | Add storage for actor handle/context refs. [ASSUMED] |
| `src/gene/types/core/native_helpers.nim` | Native converters exist for `Thread` and `ThreadMessage` only. [VERIFIED: src/gene/types/core/native_helpers.nim:12-20] | Add actor/context converters so native APIs can return handles directly. [ASSUMED] |
| `src/gene/types/runtime_types.nim`, `src/gene/vm/core_helpers.nim`, `tests/test_extended_types.nim` | Runtime type naming, class lookup, and ValueKind completeness tests already special-case `VkFuture` / `VkThread` / `VkThreadMessage`. [VERIFIED: src/gene/types/runtime_types.nim; src/gene/vm/core_helpers.nim:347-358; tests/test_extended_types.nim:7-13] | Update completeness and class-resolution paths for new actor kinds. [ASSUMED] |
| `src/gene/vm/thread_native.nim` | It owns the current Channel implementation, thread pool slot bookkeeping, `Thread.send`, `Thread.send_expect_reply`, and `Thread.on_message`. [VERIFIED: src/gene/vm/thread_native.nim:5-58; src/gene/vm/thread_native.nim:234-467] | Reuse Channel and worker-slot substrate; keep Thread API compatibility while adding actor-aware mailbox/scheduler helpers or splitting them into a sibling module. [VERIFIED: codebase grep] [ASSUMED] |
| `src/gene/vm/runtime_helpers.nim` | It owns worker bootstrap, per-thread VM setup, current message loop, and `spawn_thread`. [VERIFIED: src/gene/vm/runtime_helpers.nim:55-95; src/gene/vm/runtime_helpers.nim:98-248; src/gene/vm/runtime_helpers.nim:251-308] | Add or share the actor worker loop here so actor workers reuse the same VM bootstrap path. [ASSUMED] |
| `src/gene/vm/async.nim` and `src/gene/vm/async_exec.nim` | These files own `FutureObj` lifecycle, late-callback scheduling, and reply completion from worker messages. [VERIFIED: src/gene/vm/async.nim:61-71; src/gene/vm/async.nim:98-176; src/gene/vm/async_exec.nim:129-219] | Reuse `FutureObj` for actor reply futures and extend polling to actor reply envelopes. [VERIFIED: codebase grep] [ASSUMED] |
| `src/gene/stdlib/freeze.nim` and `docs/handbook/freeze.md` | Phase 1.5 already made frozen closures actor-ready and explicitly says Phase 2 consumes that rule. [VERIFIED: src/gene/stdlib/freeze.nim:77-185; docs/handbook/freeze.md:75-112; docs/handbook/freeze.md:149-155] | Use as-is for send-tier classification; Phase 2 should not reopen closure freeze semantics unless a bug appears. [VERIFIED: codebase grep] |
| `src/gene/compiler/async.nim` and `src/gene/vm/exec.nim` | Bare `spawn` currently compiles to `IkSpawnThread` and executes `spawn_thread`. [VERIFIED: src/gene/compiler/async.nim:48-77; src/gene/vm/exec.nim:4491-4499] | Keep unchanged for thread compatibility unless a later migration phase intentionally aliases actor spawn. [VERIFIED: codebase grep] |
| `src/gene/stdlib/core.nim` and `src/gene/vm.nim` | Core stdlib init already registers `Future`, `Thread`, `ThreadMessage`, `run_forever`, and `keep_alive`. [VERIFIED: src/gene/stdlib/core.nim:4122-4126; src/gene/stdlib/core.nim:4191-4198; src/gene/vm.nim:98-121] | Add `gene/actor` namespace/class registration and import any new actor module. [ASSUMED] |
| `src/genex/http.nim`, `src/genex/ai/bindings.nim`, `src/gene/vm/extension.nim` | These files already rely on `run_forever`, scheduler callbacks, and thread-based request dispatch. [VERIFIED: src/genex/http.nim:34-38; src/genex/http.nim:1052-1088; src/genex/ai/bindings.nim:980-999; src/gene/vm/extension.nim:80-105] | Compatibility watchlist only for Phase 2; do not migrate them to actors yet. [VERIFIED: .planning/ROADMAP.md] |

### Pattern 1: Add Actors as Native Runtime Types, Not a New Compiler Special Form
**What:** Expose actors via native classes/functions under a namespace like `gene/actor`, while leaving bare `spawn` as the legacy thread special form for Phase 2. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/exec.nim; docs/handbook/freeze.md] [ASSUMED]

**When to use:** For the Phase 2 MVP public surface, because the compiler already owns `spawn` and the roadmap keeps thread compatibility until Phase 4. [VERIFIED: .planning/ROADMAP.md; src/gene/compiler/async.nim]

**Example:**
```nim
# Source basis: current Future/Thread class registration in
# src/gene/vm/async.nim and src/gene/vm/thread_native.nim
proc init_actor_namespace*() =
  let actor_ns = new_namespace("actor")
  actor_ns["enable".to_key()] = NativeFn(actor_enable).to_value()
  actor_ns["spawn".to_key()] = NativeFn(actor_spawn).to_value()
  App.app.gene_ns.ref.ns["actor".to_key()] = actor_ns.to_value()
```

### Pattern 2: Reuse Worker Bootstrap and Channel Substrate, But Not the Thread User API
**What:** Keep using the existing worker-slot bookkeeping, `Channel[T]`, `createThread`, and per-thread VM bootstrap, but route actor work through separate actor records and ready queues. [VERIFIED: src/gene/vm/thread_native.nim; src/gene/vm/runtime_helpers.nim] [CITED: docs/proposals/actor-design.md]

**When to use:** For scheduler construction and worker startup/shutdown, because those mechanics already exist and are exercised by current thread tests and HTTP worker dispatch. [VERIFIED: tests/integration/test_thread.nim; src/genex/http.nim]

**Example:**
```text
existing pieces to reuse:
- Channel[T] in src/gene/vm/thread_native.nim:5-58
- worker slot allocation in src/gene/vm/thread_native.nim:107-203
- per-thread VM setup in src/gene/vm/runtime_helpers.nim:55-95
- OS-thread launch in src/gene/vm/runtime_helpers.nim:264-281
```

### Pattern 3: Tiered Send Must Consume the Completed Phase 1.5 Closure-Freeze Contract
**What:** Send classification should be `primitive -> by value`, `deep_frozen/shared -> pointer-share`, `mutable -> deep clone`, and frozen closures should flow through the same fast path as any other frozen graph. [VERIFIED: src/gene/types/core/value_ops.nim:228-355; src/gene/stdlib/freeze.nim:127-185; docs/handbook/freeze.md:75-112] [CITED: docs/proposals/actor-design.md]

**When to use:** In actor send methods, actor spawn validation for handlers, and any internal mailbox forwarding path. [VERIFIED: user prompt; codebase grep]

**Example:**
```text
primitive send: enqueue raw Value directly
frozen send:   retain shared root, enqueue pointer
mutable send:  deep-clone mutable spine, preserve aliasing with memo table,
               pointer-share frozen subgraphs
```

### Pattern 4: Reply Futures Should Extend `FutureObj` and `await`, Not Replace Them
**What:** The actor reply mechanism should complete ordinary `FutureObj` instances so `await`, late callbacks, timeout handling, and terminal-state rules keep the same semantics users already have. [VERIFIED: src/gene/types/core/futures.nim; src/gene/vm/async.nim; src/gene/vm/async_exec.nim]

**When to use:** For `send_expect_reply`, handler `ctx.reply`, and stop-time failure of outstanding replies. [CITED: docs/proposals/future/actor_support.md] [ASSUMED]

**Example:**
```nim
# Source basis: src/gene/vm/async_exec.nim:156-187
if pendingReplies.hasKey(replyId):
  let fut = pendingReplies[replyId]
  discard fut.complete(payload)
  vm.execute_future_callbacks(fut)
```

### Anti-Patterns to Avoid
- **Rebinding bare `spawn` in Phase 2:** It collides with the existing `IkSpawnThread` special form and muddies the compatibility boundary that Phase 4 is supposed to own. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/exec.nim; .planning/ROADMAP.md] [ASSUMED]
- **Extending `serialize_literal` for actor messages:** This re-entrenches the exact transport path the approved actor design replaces. [VERIFIED: src/gene/vm/thread_native.nim; src/gene/serdes.nim] [CITED: docs/proposals/actor-design.md]
- **Touching HTTP / AI thread workers in Phase 2:** Those are current thread consumers and future Phase 3 port-actor migration targets, not actor-runtime MVP scope. [VERIFIED: src/genex/http.nim; src/genex/ai/bindings.nim; .planning/ROADMAP.md]
- **Adding a second process-level scheduler loop:** `run_forever` already drives extension callbacks and async polling; actors should integrate with that story or run independently behind `gene/actor/enable`, not compete with it. [VERIFIED: src/gene/stdlib/core.nim; src/gene/types/memory.nim; src/gene/vm/extension.nim]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Reply futures | A second promise type just for actors | Existing `FutureObj`, `await`, and callback execution paths. [VERIFIED: src/gene/types/core/futures.nim; src/gene/vm/async.nim; src/gene/vm/async_exec.nim] | Reuse keeps user semantics and failure handling aligned with the rest of the runtime. [VERIFIED: codebase grep] |
| Mailbox substrate | A brand-new queue/condvar implementation | The existing `Channel[T]` in `src/gene/vm/thread_native.nim`. [VERIFIED: src/gene/vm/thread_native.nim:5-58] | The codebase already depends on this channel for cross-thread messaging, and actor mailboxes can build on the same primitive. [VERIFIED: codebase grep] |
| Sendability checks | Actor-specific closure eligibility logic | `deep_frozen/shared` plus the Phase 1.5 closure-freeze rule. [VERIFIED: src/gene/stdlib/freeze.nim; docs/handbook/freeze.md] | Phase 1.5 already solved the closure question that actors need. [VERIFIED: .planning/phases/01.5-freezable-closures/01.5-02-SUMMARY.md] |
| Process scheduler integration | A separate extension tick mechanism | Existing `run_forever` and `register_scheduler_callback`. [VERIFIED: src/gene/stdlib/core.nim:2433-2480; src/gene/types/memory.nim:15-23; src/gene/vm/extension.nim:95-105] | HTTP and AI extensions already use these hooks, so splitting the scheduler would add compatibility risk immediately. [VERIFIED: src/genex/http.nim; src/genex/ai/bindings.nim] |

**Key insight:** The fastest path to a plannable Phase 2 is not "build actors from scratch"; it is "add actor types and scheduling above the verified thread/future/freeze substrate while leaving the thread surface visible but secondary." [VERIFIED: codebase grep] [CITED: docs/proposals/actor-design.md]

## Common Pitfalls

### Pitfall 1: Public API Collision With Existing `spawn`
**What goes wrong:** The plan assumes actor spawn can reuse the current `spawn` syntax immediately, but `spawn` already compiles to `IkSpawnThread` and returns a `Thread` or `Future`. [VERIFIED: src/gene/compiler/async.nim:48-77; src/gene/vm/exec.nim:4491-4499]
**Why it happens:** The older actor proposal uses `gene/actor/spawn`, while `actor-design.md` later uses bare `(spawn)` in narrative examples. [VERIFIED: docs/proposals/future/actor_support.md; docs/proposals/actor-design.md]
**How to avoid:** Lock the Phase 2 API surface before implementation; the low-risk choice is `gene/actor/*` first, with any aliasing deferred. [ASSUMED]
**Warning signs:** A plan that edits compiler async opcodes before it introduces an `Actor` runtime type. [VERIFIED: codebase grep]

### Pitfall 2: Regressing Legacy Thread Compatibility Too Early
**What goes wrong:** Actor work starts deleting or reinterpreting `spawn`, `spawn_return`, `Thread.send`, `Thread.on_message`, or `keep_alive` during the same phase that is supposed to keep them for compatibility. [VERIFIED: docs/handbook/freeze.md:94-112; tests/integration/test_thread.nim]
**Why it happens:** The actor runtime and thread runtime reuse the same substrate, so it is easy to collapse both scopes into one patch. [VERIFIED: src/gene/vm/thread_native.nim; src/gene/vm/runtime_helpers.nim]
**How to avoid:** Treat thread code as a compatibility harness in Phase 2, not as the user-facing target architecture. [VERIFIED: .planning/ROADMAP.md]
**Warning signs:** Thread tests are being rewritten before any actor-specific tests exist. [VERIFIED: tests/integration/test_thread.nim; testsuite/10-async/threads]

### Pitfall 3: Re-Implementing Closure Send Rules in Actor Transport
**What goes wrong:** Phase 2 duplicates freeze checks or sneaks closure cases into serializer code instead of using `deep_frozen/shared`. [VERIFIED: src/gene/stdlib/freeze.nim; src/gene/serdes.nim]
**Why it happens:** The transport layer is where send failures are visible, so it is tempting to solve closure eligibility there. [VERIFIED: codebase grep]
**How to avoid:** Make Phase 2 treat "frozen closure" as just another deep-frozen shared graph. [VERIFIED: docs/handbook/freeze.md:149-155] [ASSUMED]
**Warning signs:** A send-tier design that mentions `serialize_literal` or a closure-specific whitelist before it mentions `deep_frozen/shared`. [VERIFIED: codebase grep]

### Pitfall 4: Stop Semantics That Only Flip Actor State
**What goes wrong:** `.stop` marks an actor dead but leaves queued messages or pending reply futures unresolved. [CITED: docs/proposals/future/actor_support.md]
**Why it happens:** Current thread termination is slot/channel oriented, not mailbox-future oriented. [VERIFIED: src/gene/vm/thread_native.nim:107-145; src/gene/vm/thread_native.nim:190-200]
**How to avoid:** Make stop semantics update three things together: actor lifecycle state, mailbox draining/drop policy, and pending-reply future failure. [CITED: docs/proposals/future/actor_support.md] [ASSUMED]
**Warning signs:** Tests only assert that the actor no longer runs, but do not assert failed reply futures or dropped queued messages. [ASSUMED]

### Pitfall 5: Breaking `run_forever` / Scheduler Callback Integration
**What goes wrong:** Actor scheduling assumes it owns the only process-level loop, but HTTP / AI extensions already depend on `run_forever` and scheduler callbacks. [VERIFIED: src/gene/stdlib/core.nim:2433-2480; src/gene/vm/extension.nim:95-105; src/genex/http.nim:480-568; src/genex/ai/bindings.nim:980-999]
**Why it happens:** The codebase uses "scheduler" both for extension event-loop polling and for actor scheduling, but they are not the same subsystem today. [VERIFIED: codebase grep]
**How to avoid:** Keep actor enable/worker startup separate from `run_forever`, and preserve the existing scheduler-callback contract. [ASSUMED]
**Warning signs:** A design that removes `scheduler_callbacks` or changes `run_forever` semantics as part of ACT-02. [VERIFIED: src/gene/types/memory.nim; src/gene/stdlib/core.nim]

## Code Examples

Verified patterns from current sources:

### Current Thread Spawn Path
```nim
# Source: src/gene/compiler/async.nim:64-77 and src/gene/vm/exec.nim:4491-4499
let expr = if gene.children.len == 1: gene.children[0] else: new_stream_value(gene.children)
self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](expr)))
self.emit(Instruction(kind: IkPushValue, arg0: if return_value: TRUE else: FALSE))
self.emit(Instruction(kind: IkSpawnThread))

let return_value_flag = self.frame.pop()
let code_val = self.frame.pop()
let result = spawn_thread(code_val, return_value_flag == TRUE)
self.frame.push(result)
```

This is why reusing bare `spawn` for actors is high-risk during Phase 2: the spelling is already compiler-owned for threads. [VERIFIED: codebase grep]

### Current Reply-Future Completion Path
```nim
# Source: src/gene/vm/async_exec.nim:156-187
if msg.msg_type == MtReply:
  if self.thread_futures.hasKey(msg.from_message_id):
    let future_obj = self.thread_futures[msg.from_message_id]
    discard future_obj.complete(payload)
    self.execute_future_callbacks(future_obj)
    self.thread_futures.del(msg.from_message_id)
```

Phase 2 should preserve this shape conceptually even if it renames the tracking table from thread replies to actor replies. [VERIFIED: codebase grep] [ASSUMED]

### Current Phase 1.5 Freeze Contract
```nim
# Source: src/gene/stdlib/freeze.nim:127-185
of VkFunction:
  if v.ref.fn != nil:
    validate_scope_for_freeze(v.ref.fn.parent_scope, path, 0, visited)

...
of VkFunction:
  setDeepFrozen(v)
  setShared(v)
  if v.ref.fn != nil:
    tag_scope_for_freeze(v.ref.fn.parent_scope, visited)
```

This is the exact contract Phase 2 send tiers should consume for frozen closures. [VERIFIED: codebase grep]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| User concurrency is thread-first: bare `spawn`, `spawn_return`, `Thread.send`, `Thread.send_expect_reply`, literal-only payloads, and callback-based `Thread.on_message`. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/thread_native.nim; docs/thread_support.md] | Approved actor runtime target is scheduler + tiered send + reply futures + stop semantics on top of the verified substrate. [VERIFIED: .planning/ROADMAP.md; .planning/REQUIREMENTS.md] [CITED: docs/proposals/actor-design.md] | Phase 2 is the next planned phase after Phase 1.5 completion on 2026-04-19. [VERIFIED: .planning/STATE.md] | The plan should add actors without removing existing thread surfaces yet. [VERIFIED: .planning/ROADMAP.md; docs/handbook/freeze.md] |
| Cross-thread sends serialize literal values and reject functions/futures/instances. [VERIFIED: src/gene/vm/thread_native.nim:293-301; tests/test_thread_msg.nim] | Actor sends are supposed to be tiered: primitive by value, frozen by pointer, mutable by deep clone. [CITED: docs/proposals/actor-design.md] | Approved with the actor design track before Phase 0/1 started. [VERIFIED: .planning/PROJECT.md] | Phase 2 should supersede literal-only messaging as the primary model, but keep it alive for thread compatibility. [VERIFIED: docs/handbook/freeze.md] |
| Closures were formerly not sendable through runtime transport. [VERIFIED: docs/thread_support.md; src/gene/serdes.nim] | Phase 1.5 now proves frozen closures are pointer-shareable and callable after scope teardown. [VERIFIED: .planning/phases/01.5-freezable-closures/01.5-02-SUMMARY.md] | Completed 2026-04-19. [VERIFIED: .planning/phases/01.5-freezable-closures/01.5-02-SUMMARY.md] | Actor handlers and payloads can now use frozen-closure fast paths without new freeze work in Phase 2. [VERIFIED: docs/handbook/freeze.md] |
| Local toolchain is Nim `2.2.4`. [VERIFIED: `nim --version`] | Current Nim stable is `2.2.8`, whose release notes explicitly call out multi-threaded allocator stability improvements. [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html] | Stable release published 2026-02-23. [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html] | Phase 2 can proceed on 2.2.4, but concurrency-specific compiler/runtime regressions should be debugged with toolchain version in mind. [VERIFIED: `nim --version`] [ASSUMED] |

**Deprecated/outdated:**
- Treating `serialize_literal` as the long-term concurrency transport is outdated against the approved actor plan. [VERIFIED: src/gene/serdes.nim; docs/thread_support.md] [CITED: docs/proposals/actor-design.md]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Phase 2 should expose actors under `gene/actor/*` instead of rebinding bare `spawn`. | Summary / Architecture Patterns / Open Questions | Planner may over-scope compiler work if the user instead wants actor spawn to take over bare `spawn` immediately. |
| A2 | The cleanest implementation split is a new actor module (`src/gene/stdlib/actor.nim` and possibly `src/gene/vm/actor*.nim`) plus minimal imports into existing runtime files. | Recommended Project Structure | Planner may assign work to new files that the implementer later decides to fold into `thread_native.nim` / `core.nim`. |
| A3 | Actor reply plumbing should reuse ordinary `FutureObj` plus actor-specific tracking, not a dedicated reply actor/channel abstraction. | Architecture Patterns / Open Questions | Planner may under-budget infrastructure if a dedicated reply mailbox/channel is chosen instead. |
| A4 | `run_forever` and extension scheduler callbacks should remain behaviorally unchanged during ACT-02. | Common Pitfalls / Validation Architecture | Planner may miss necessary integration work if actor scheduling is later required to cooperate more deeply with `run_forever`. |

## Open Questions (RESOLVED FOR PLANNING)

1. **What is the Phase 2 public API spelling?**
   - **Decision:** Introduce the actor surface under `gene/actor/*` in Phase 2 and leave bare `spawn` / `spawn_return` untouched for thread compatibility.
   - **Why:** bare `spawn` already compiles to `IkSpawnThread`, and Phase 4 is where thread-first surfaces are retired. Rebinding it in Phase 2 would widen the migration blast radius into compiler compatibility work too early. [VERIFIED: src/gene/compiler/async.nim; src/gene/vm/exec.nim; .planning/ROADMAP.md] [CITED: docs/proposals/future/actor_support.md]

2. **How should a full mailbox behave?**
   - **Decision:** Phase 2 uses bounded mailboxes with non-blocking backpressure: park actor senders when the target mailbox is full, and allow blocking only from non-actor entrypoints.
   - **Why:** blocking a worker thread on mailbox pressure would stall unrelated ready actors on that worker. The later `actor-design.md` recommendation is the safer default for the runtime we already have. [CITED: docs/proposals/actor-design.md]

3. **What should happen when an actor handler throws?**
   - **Decision:** The actor remains alive, the current reply future fails, and the failure is surfaced to the caller without killing the whole actor by default.
   - **Why:** this matches the current thread runtime’s more tolerant callback posture and keeps Phase 2’s lifecycle/state machine simpler than introducing actor death semantics immediately. [VERIFIED: src/gene/vm/runtime_helpers.nim:202-216] [CITED: docs/proposals/future/actor_support.md]

4. **Where should mutable deep-clone results live?**
   - **Decision:** Mutable send clones live on the shared heap with `shared=false` for the MVP, exactly as the approved actor design recommends.
   - **Why:** receiver-local allocation is explicitly deferred because it needs scheduler coordination; Phase 2 should use the documented MVP rule first. [CITED: docs/proposals/actor-design.md]

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Nim compiler | All Phase 2 code and tests | ✓ [VERIFIED: `command -v nim`] | `2.2.4` [VERIFIED: `nim --version`] | Upgrade to current stable `2.2.8` if a concurrency/compiler bug appears. [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html] |
| Nimble | Repo task execution (`nimble test`, `nimble testintegration`) | ✓ [VERIFIED: `command -v nimble`] | `0.18.2` [VERIFIED: `nimble --version`] | Run direct `nim c -r ...` commands per file. [VERIFIED: gene.nimble] |
| Clang toolchain | Native compilation on this macOS host | ✓ [VERIFIED: `command -v clang`] | Apple clang `21.0.0` [VERIFIED: `clang --version`] | `gcc` resolves to the same Apple clang toolchain on this host. [VERIFIED: `gcc --version`; `clang --version`] |
| Bash test runner | `./testsuite/run_tests.sh` | ✓ [VERIFIED: codebase grep] | system shell [VERIFIED: environment] | None needed. |

**Missing dependencies with no fallback:**
- None identified for ACT-02 research and planning. [VERIFIED: local environment probe]

**Missing dependencies with fallback:**
- The local Nim toolchain is behind current stable (`2.2.4` vs `2.2.8`), but Phase 2 can still be planned and implemented on the installed version unless a concurrency-specific compiler/runtime issue appears. [VERIFIED: `nim --version`] [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html]

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Nim `std/unittest` plus Gene `testsuite` shell runner. [VERIFIED: tests/README.md; testsuite/run_tests.sh] |
| Config file | none — test commands are declared in `gene.nimble` and `testsuite/run_tests.sh`. [VERIFIED: gene.nimble; testsuite/run_tests.sh] |
| Quick run command | `nim c -r --threads:on tests/test_phase2_actor_send_tiers.nim && nim c -r tests/integration/test_actor_runtime.nim && nim c -r tests/integration/test_actor_reply_futures.nim && nim c -r tests/integration/test_actor_stop_semantics.nim` [ASSUMED] |
| Full suite command | `nimble test && nimble testintegration && ./testsuite/run_tests.sh` [VERIFIED: gene.nimble; testsuite/run_tests.sh] |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ACT-02 | Actor enable/spawn creates a live actor, pins it to a worker, and processes one message at a time. [VERIFIED: .planning/REQUIREMENTS.md] | integration | `nim c -r tests/integration/test_actor_runtime.nim` [ASSUMED] | ❌ Wave 0 |
| ACT-02 | Send tiers distinguish primitives, frozen values, frozen closures, and mutable graphs. [VERIFIED: .planning/ROADMAP.md; docs/handbook/freeze.md] | unit + stress | `nim c -r --threads:on tests/test_phase2_actor_send_tiers.nim` [ASSUMED] | ❌ Wave 0 |
| ACT-02 | `send_expect_reply` returns a Future that completes, fails, and times out correctly. [VERIFIED: .planning/REQUIREMENTS.md; src/gene/vm/async_exec.nim] | integration | `nim c -r tests/integration/test_actor_reply_futures.nim` [ASSUMED] | ❌ Wave 0 |
| ACT-02 | Stop semantics drop queued work, fail pending reply futures, and reject sends to stopped actors. [CITED: docs/proposals/future/actor_support.md] [ASSUMED] | integration | `nim c -r tests/integration/test_actor_stop_semantics.nim` [ASSUMED] | ❌ Wave 0 |
| ACT-02 | Legacy thread/future behavior still works during compatibility window. [VERIFIED: docs/handbook/freeze.md; tests/integration/test_thread.nim; tests/test_thread_msg.nim; tests/integration/test_future_callbacks.nim] | regression | `nim c -r tests/integration/test_thread.nim && nim c -r tests/test_thread_msg.nim && nim c -r tests/integration/test_future_callbacks.nim` [VERIFIED: gene.nimble] | ✅ |

### Sampling Rate
- **Per task commit:** run the new phase-targeted actor tests plus the existing thread/future regression trio. [ASSUMED]
- **Per wave merge:** `nimble test && nim c -r tests/integration/test_thread.nim && nim c -r tests/integration/test_future_callbacks.nim && ./testsuite/run_tests.sh testsuite/10-async/threads/1_send_expect_reply.gene testsuite/10-async/threads/2_keep_alive_reply.gene` [VERIFIED: gene.nimble; testsuite/run_tests.sh]
- **Phase gate:** full suite green before `/gsd-verify-work`. [VERIFIED: .planning/config.json]

### Wave 0 Gaps
- [ ] `tests/test_phase2_actor_send_tiers.nim` — direct unit/stress coverage for primitive, frozen, frozen-closure, mutable, alias-preserving clone, and capability-rejection cases. [ASSUMED]
- [ ] `tests/integration/test_actor_runtime.nim` — actor spawn, state threading through handler return value, one-message-at-a-time scheduling, and worker pinning. [ASSUMED]
- [ ] `tests/integration/test_actor_reply_futures.nim` — reply success, missing reply error, handler failure propagation, timeout, and late callback behavior. [ASSUMED]
- [ ] `tests/integration/test_actor_stop_semantics.nim` — `ctx/.stop`, external `.stop`, dropped queued messages, pending-future failure, and send-to-dead rejection. [ASSUMED]
- [ ] `testsuite/10-async/actors/` — Gene-level actor semantics examples analogous to the existing `testsuite/10-async/threads/` coverage. [VERIFIED: testsuite/10-async structure] [ASSUMED]
- [ ] `tests/test_extended_types.nim` updates — ValueKind completeness must be extended if new actor kinds are added. [VERIFIED: tests/test_extended_types.nim]

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no [ASSUMED] | N/A |
| V3 Session Management | no [ASSUMED] | N/A |
| V4 Access Control | yes [ASSUMED] | Actor/Thread handle validation should mirror the existing `id + secret` validity checks used by `Thread`. [VERIFIED: src/gene/vm/thread_native.nim:277-284; src/gene/vm/thread_native.nim:353-359] |
| V5 Input Validation | yes [VERIFIED: current runtime uses native arg validation widely] | Native API argument checks via `get_positional_arg`, explicit kind checks, and clear runtime exceptions. [VERIFIED: src/gene/types/core/native_helpers.nim; src/gene/vm/thread_native.nim; src/gene/vm/async.nim] |
| V6 Cryptography | no [ASSUMED] | N/A |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Mutable alias leakage across actor boundaries | Tampering | Only pointer-share `deep_frozen/shared` values; deep-clone mutable values and preserve aliasing with a memo table. [VERIFIED: src/gene/types/memory.nim; src/gene/types/core/value_ops.nim] [CITED: docs/proposals/actor-design.md] |
| Capability/value leakage across actor boundaries | Elevation of Privilege | Reject non-sendable capability values and keep native resources behind later port actors. [CITED: docs/proposals/actor-design.md] [VERIFIED: src/gene/serdes.nim; docs/handbook/freeze.md] |
| Mailbox exhaustion / actor-flood denial of service | Denial of Service | Use bounded mailboxes and an explicit overflow policy decided before implementation. [VERIFIED: docs/proposals/future/actor_support.md; docs/proposals/actor-design.md] |
| Stale-handle send or stop against dead actor | Spoofing / DoS | Validate actor handle liveness similarly to current `Thread` secret checks and reject sends after stop. [VERIFIED: src/gene/vm/thread_native.nim:277-284; src/gene/vm/thread_native.nim:353-359] [ASSUMED] |
| Scheduler-loop regressions that starve extensions | Denial of Service | Preserve `run_forever` and `scheduler_callbacks` behavior while actors are added. [VERIFIED: src/gene/stdlib/core.nim; src/gene/types/memory.nim; src/gene/vm/extension.nim] |

## Sources

### Primary (HIGH confidence)
- `docs/proposals/actor-design.md` — approved actor migration design, send tiers, worker-pool reuse, and Phase 2/3/4 boundaries. [VERIFIED: local file]
- `docs/handbook/freeze.md` — current Phase 1 / 1.5 freeze boundary and explicit Phase 2 handoff. [VERIFIED: local file]
- `docs/thread_support.md` — current shipped thread API and its sharp edges. [VERIFIED: local file]
- `src/gene/vm/thread_native.nim`, `src/gene/vm/runtime_helpers.nim`, `src/gene/vm/async.nim`, `src/gene/vm/async_exec.nim`, `src/gene/types/type_defs.nim`, `src/gene/types/reference_types.nim`, `src/gene/types/core/value_ops.nim`, `src/gene/stdlib/freeze.nim`, `src/gene/stdlib/core.nim` — exact runtime surfaces that Phase 2 must reuse or change. [VERIFIED: codebase grep]
- `https://nim-lang.org/docs/typedthreads.html` — official current `createThread` / `joinThread` / ORC shared-heap thread guidance. [CITED: https://nim-lang.org/docs/typedthreads.html]
- `https://nim-lang.org/docs/atomics.html` — official current `Atomic[T]`, `compareExchange`, and memory-order API. [CITED: https://nim-lang.org/docs/atomics.html]
- `https://nim-lang.org/docs/asyncdispatch.html` and `https://nim-lang.org/docs/asyncfutures.html` — official current async dispatcher and future callback behavior. [CITED: https://nim-lang.org/docs/asyncdispatch.html] [CITED: https://nim-lang.org/docs/asyncfutures.html]

### Secondary (MEDIUM confidence)
- `docs/proposals/future/actor_support.md` — older actor MVP proposal with concrete API and stop/reply behavior, but partially superseded by `actor-design.md`. [VERIFIED: local file]
- `https://nim-lang.org/blog/2026/02/23/nim-228.html` — current stable Nim release note used for toolchain currency and multithreaded allocator note. [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html]

### Tertiary (LOW confidence)
- None. All external claims were tied to official Nim documentation or release notes, and all repo-specific claims were verified against local files. [VERIFIED: source review]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — the phase builds on existing repo code plus official Nim stdlib docs. [VERIFIED: codebase grep] [CITED: nim-lang.org docs]
- Architecture: MEDIUM — the reuse strategy is well-supported by current code, but API naming, mailbox overflow, and handler-exception semantics still need explicit decisions. [VERIFIED: codebase grep] [CITED: docs/proposals/actor-design.md] [CITED: docs/proposals/future/actor_support.md]
- Pitfalls: HIGH — the main failure modes are visible directly in current thread/future code and the Phase 1.5 handoff docs. [VERIFIED: codebase grep]

**Research date:** 2026-04-20  
**Valid until:** 2026-05-20 for codebase mapping; re-check Nim stable/toolchain notes sooner if the local compiler changes. [VERIFIED: `nim --version`] [CITED: https://nim-lang.org/blog/2026/02/23/nim-228.html]
