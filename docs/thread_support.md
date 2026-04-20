# Thread Support in the Gene VM (current implementation)

Phase 2 introduces actors as the primary public concurrency surface.

This page now documents the surviving thread-first API as a compatibility
boundary for existing code and migration cases. For new concurrent work, start
with [docs/handbook/actors.md](/Users/gcao/gene-workspace/gene-old/docs/handbook/actors.md).

This document describes the thread system as implemented in the Nim VM today (not the older design notes).

## High-level model

- **Thread pool**: fixed-size pool of OS threads (`MAX_THREADS = 64`), with thread id `0` reserved for the main thread (`src/gene/types/value_core.nim`).
- **Per-thread VM**: `VM` is a Nim `threadvar` (`var VM {.threadvar.}: ptr VirtualMachine`), so every OS thread gets its own VM instance (`src/gene/types/value_core.nim`).
- **Shared App**: `App` (namespaces, classes, etc.) is shared across all threads and treated as read-only after initialization (`src/gene/types/value_core.nim`).
- **Communication**: message passing via per-thread channels, with cross-thread isolation enforced by **literal-only serialization** (`serialize_literal` / `deserialize_literal`) (`src/gene/vm/thread.nim`, `src/gene/serdes.nim`).

## Language surface area

### `spawn` / `spawn_return`

- `(spawn expr)` spawns a new worker thread, executes `expr` once on that worker, and returns a **Thread handle**.
- `(spawn_return expr)` is syntax sugar for `(spawn ^return true expr)` and returns a **Future**.
- `spawn_return` results are consumed via `(await ...)`.

Compiler:
- `compile_spawn` emits `IkSpawnThread` with the unevaluated Gene AST as data (`src/gene/compiler.nim`).

VM:
- `IkSpawnThread` calls `spawn_thread(code, return_value)` (`src/gene/vm.nim`, `src/gene/vm/runtime_helpers.nim`).

### Thread-local handles: `$thread`, `$main_thread`

Every thread has a thread-local namespace which provides:

- `$thread` / `thread` — the current thread handle
- `$main_thread` / `main_thread` — the main thread handle (id 0)

These are resolved specially during symbol lookup via `VM.thread_local_ns` (`src/gene/vm.nim`, `src/gene/types/helpers.nim`, `src/gene/vm/runtime_helpers.nim`).

### `Thread` and `ThreadMessage` classes

`Thread` is a native class exposed in the `gene` namespace during VM initialization (`src/gene/vm/thread.nim`):

- `Thread.send(thread, payload, ^reply true?)`
- `Thread.send_expect_reply(thread, payload)` (forces reply)
- `Thread.on_message(thread, callback)` registers per-thread message callbacks

`ThreadMessage` is the message object delivered to callbacks:

- `ThreadMessage.payload(msg)` returns the decoded payload
- `ThreadMessage.reply(msg, value)` replies to the sender (used when the sender requested a reply)

There is also a top-level helper function inserted into the `gene` namespace:

- `(send_expect_reply thread payload)` → returns a Future of the reply (`src/gene/vm/thread.nim`).

## Execution details

### How `spawn` actually runs code

1. `spawn_thread` allocates a free thread slot (`get_free_thread`), initializes metadata, starts an OS thread, and enqueues a message containing the **Gene AST** (`MtRun` / `MtRunExpectReply`) (`src/gene/vm/runtime_helpers.nim`, `src/gene/vm/thread.nim`).
2. The OS thread runs `thread_handler` which:
   - creates a per-thread VM (`init_vm_for_thread`)
   - blocks on its channel (`recv`)
   - on each message, resets VM state and executes according to message type (`src/gene/vm/runtime_helpers.nim`).
3. For `MtRun` / `MtRunExpectReply`, the worker:
   - compiles the Gene AST locally via `compile_init(msg.code)` (so it does **not** share `CompilationUnit` refs across threads)
   - sets up a fresh frame/scope
   - executes via `VM.exec()` (`src/gene/vm/runtime_helpers.nim`).

### How results and replies get back to the main thread

- `spawn_return` uses a **Future** created on the caller VM (`VM.thread_futures[message_id] = future_obj`) and marks `poll_enabled = true` (`src/gene/vm/runtime_helpers.nim`, `src/gene/vm.nim`).
- Replies (`MtReply`) are received on thread 0’s channel and completed in:
  - the normal instruction loop via `poll_event_loop` (periodic), and
  - the `IkAwait` slow path while awaiting a pending future (`src/gene/vm.nim`).

### Message passing semantics

- `.send` and `.send_expect_reply` **serialize** the payload into `msg.payload_bytes` using `serialize_literal` before putting it on the destination channel (`src/gene/vm/thread.nim`).
- The receiver thread **deserializes** payload bytes into a fresh value graph and calls all registered `vm.message_callbacks` (`src/gene/vm/runtime_helpers.nim`).
- If the sender requested a reply and no callback called `.reply`, the runtime sends an implicit `NIL` reply (`src/gene/vm/runtime_helpers.nim`).

## Safety rules (literal-only payloads)

Cross-thread payloads are restricted to “literal” values:

- Allowed: primitives, strings/symbols, arrays/maps whose contents are literal.
- Rejected: functions/blocks, classes, instances, threads, futures, namespaces, etc.

This is enforced by `serialize_literal` (`src/gene/serdes.nim`) and covered by tests (`tests/test_thread_msg.nim`).

## Important limitations / sharp edges

### 1) `spawn_return` threads are currently “unowned”

`spawn_return` returns only a Future, not a Thread handle. The worker thread remains alive in the thread loop waiting for messages, but the caller has no handle to terminate it. Repeated `spawn_return` calls can exhaust `MAX_THREADS` in long-running processes.

If you need many concurrent jobs, prefer:

- spawning a worker thread once (keep the handle) and using message passing, or
- using actors when the workload fits the Phase 2 actor model, or
- adding an explicit “terminate after job” behavior to `MtRunExpectReply` (not implemented today).

### 2) `keep_alive` is a placeholder and will block message processing

`keep_alive` is currently an infinite sleep loop (`src/gene/vm/thread.nim`). Calling it inside a `spawn` job prevents the worker from returning to its channel receive loop.

### 3) Main thread does not dispatch `MtSend` user messages today

Worker threads dispatch `MtSend` / `MtSendExpectReply` via `vm.message_callbacks`. The main thread’s polling currently focuses on `MtReply` for futures; plain “send to main thread” is not wired up.

### 4) Global caches are not synchronized

The module cache (`ModuleCache` in `src/gene/vm/module.nim`) is a global table without locking. Concurrent imports from multiple threads may race.

### 5) Extensions can impose extra constraints

Some extensions wrap Nim ref objects that are not safe to share across threads. Example: the LLM app runs sequentially because model/session state is GC-managed and thread-local on the Nim side (`example-projects/llm_app/backend/src/main.gene`).

## Reference tests

- `tests/test_thread.nim` — spawn/spawn_return, reply futures, message callbacks
- `tests/test_thread_msg.nim` — payload serialization constraints
