# 10. Async & Concurrency

## 10.1 Async / Await

```gene
# Wrap a value in a completed Future
(var f (async (compute_something)))

# Retrieve the result
(var result (await f))
```

- `async` evaluates the expression **synchronously**, then wraps its result in a completed Future
- It does **not** automatically make slow operations run in the background
- Its purpose is to unify code paths — e.g., when one branch returns a Future and another returns a plain value, wrapping the plain value with `async` lets both branches be handled uniformly with `await`
- `await` blocks until the future completes, polling the event loop

### Unifying Sync and Async Branches

```gene
# fetch_data returns a Future, but fallback is a plain value.
# Wrapping the fallback with async lets both be awaited uniformly.
(var f
  (if use_network
    (fetch_data "url")       # Already a Future
  else
    (async cached_value)))   # Wrap plain value as a completed Future

(var result (await f))       # Works for both branches
```

### True Concurrent Operations

Real concurrency comes from async I/O functions that integrate with the event loop (see 10.2), not from wrapping synchronous code with `async`:

```gene
(var f1 (fetch_data "url1"))   # Returns Future, starts I/O
(var f2 (fetch_data "url2"))   # Returns Future, starts I/O
(var r1 (await f1))            # f1 and f2 execute concurrently
(var r2 (await f2))
```

## 10.2 Async I/O

Real async operations that integrate with the event loop:

```gene
# File I/O
(var text (await (gene/io/read_async "file.txt")))
(await (gene/io/write_async "out.txt" "content"))

# HTTP
(var resp (await (http_get "https://example.com")))

# Sleep
(await (gene/sleep_async 1000))   # Milliseconds
```

## 10.3 Future State & Callbacks

```gene
# Check state
future/.state     # => pending | success | failure | cancelled

# Callbacks
(f .on_success (fn [value] (println "Got:" value)))
(f .on_failure (fn [error] (println "Error:" error/message)))

# Manual future: complete, fail, cancel
(var f (new gene/Future))
(f .complete 42)           # resolve with a value
(await ^timeout 0.5 f)

(var f2 (new gene/Future))
(f2 .fail "something broke")   # reject; error normalized to Exception
(try (await f2) catch * (println $ex/message))

(var f3 (new gene/Future))
(f3 .cancel)               # cancel with default reason
```

| Method | State after | `await` behaviour |
|--------|-------------|-------------------|
| `.complete value` | `success` | returns value |
| `.fail error` | `failure` | re-throws as `Exception` |
| `.cancel` | `cancelled` | throws `CancellationException` |

All three raise if called on an already-terminal future.

## 10.4 Error Handling in Async

Exceptions in async blocks are captured by the future and re-thrown on `await`:

```gene
(var f (async (throw "boom")))
(try
  (await f)
catch *
  (println "Caught:" $ex))
```

## 10.5 Actors

Actors are Gene's public message-passing concurrency API. The older
thread-first surface has been retired from user code; native worker threads
remain an internal runtime substrate for scheduling actors.

```gene
(gene/actor/enable)

(var counter
  (gene/actor/spawn
    ^state 0
    (fn [ctx msg state]
      (var next (+ state msg))
      (ctx .reply next)
      next)))

(await (counter .send_expect_reply 41))   # => 41
(await (counter .send_expect_reply 1))    # => 42
```

Actor messages use tiered send semantics:

- **Primitives** are sent by value.
- **Frozen graphs and frozen closures** may be shared by pointer.
- **Mutable ordinary data** is cloned for the receiving actor.
- **Runtime capabilities** such as native handles, futures, active generators,
  and raw internal resources are actor-local and must cross actor boundaries
  through a port actor or an explicit value protocol.

### Worker Limits

- The actor runtime is disabled by default; call `gene/actor/enable` before
  spawning actors.
- `gene/actor/enable ^workers N` controls the internal worker pool size.
- Each worker has its own VM execution context and message channel.
- New code should use `gene/actor/*`; do not use the retired thread-first
  helpers.

---

## Potential Improvements

- **Structured concurrency**: No built-in way to manage groups of futures (wait-all / wait-any). Must manually track and await each.
- **`async for`**: No async iteration protocol. Cannot `for` over a stream of async values.
- **Actor supervision**: No built-in supervision tree or monitor API yet.
- **Channel type**: Message passing is actor-oriented. A first-class Channel type is intentionally not part of the stable surface yet.
- **Worker scheduler**: Native OS workers back actors internally. A work-stealing M:N scheduler would reduce hot-worker imbalance for high-concurrency workloads.
- **Async in constructors/methods**: Async works in functions but the interaction with class constructors and method dispatch may have edge cases.
- **Event loop visibility**: The internal polling interval (every 100 instructions) is not configurable and not visible to users.
