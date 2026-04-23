---
quick_id: 260423-le7
status: complete
completed: 2026-04-23
commit: e0a28df
---

# Quick Task 260423-le7 Summary

## Goal

Harden actor runtime concurrency concerns while leaving the existing `__thread_error__` reply envelope unchanged by explicit user direction.

## Changes

- Added a shared `next_thread_message_id()` allocator and routed actor/runtime helper message creation through it.
- Isolated actor initial state with the actor send-tier preparation path.
- Made actor handles explicitly sendable by cloning their id wrapper.
- Rejected `VkBlock` actor handlers until block capture sendability is implemented.
- Bounded actor-originated parked sends to the mailbox limit and fail fast with `Actor mailbox is full`.
- Added regressions for actor-handle transport, block rejection, state isolation, and bounded parked sends.

## Verification

- `nim c -r tests/test_phase2_actor_send_tiers.nim`
- `nim c -r tests/integration/test_actor_runtime.nim`
- `nim c -r tests/integration/test_actor_reply_futures.nim`
- `nim c -r tests/integration/test_actor_stop_semantics.nim`
- `nim c -r tests/test_actor_runtime_types.nim`
- `nim c -r tests/test_thread_msg.nim`
- `nim c -r tests/integration/test_thread.nim`
- `nimble test`

## Files Changed

- `src/gene/vm/actor.nim`
- `src/gene/vm/runtime_helpers.nim`
- `src/gene/vm/thread.nim`
- `src/gene/vm/thread_native.nim`
- `tests/test_phase2_actor_send_tiers.nim`

## Remaining Risks

- `VkBlock` actor handlers remain unsupported until a dedicated block capture freeze/sendability design lands.
- The `__thread_error__` map envelope was intentionally not changed.
