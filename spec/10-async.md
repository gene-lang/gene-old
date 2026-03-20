# 10. Async & Concurrency

## 10.1 Async / Await

```gene
# Create a future
(var f (async (expensive_computation)))

# Wait for result
(var result (await f))
```

- `async` wraps an expression in a Future, returns immediately
- `await` blocks until the future completes, polling the event loop
- Multiple futures can execute concurrently

### Concurrent Operations
```gene
(var f1 (async (fetch_data "url1")))
(var f2 (async (fetch_data "url2")))
(var r1 (await f1))
(var r2 (await f2))
# f1 and f2 execute concurrently
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
(await (sleep_async 1000))   # Milliseconds
```

## 10.3 Future State & Callbacks

```gene
# Check state
future/.state     # "pending", "completed", "failed"

# Callbacks
(f .on_success (fn [value] (println "Got:" value)))
(f .on_failure (fn [error] (println "Error:" error)))
```

## 10.4 Error Handling in Async

Exceptions in async blocks are captured by the future and re-thrown on `await`:

```gene
(var f (async (throw "boom")))
(try
  (await f)
catch *
  (println "Caught:" $ex))
```

## 10.5 Threads

Gene supports OS threads with message passing:

```gene
# Create and run
(var t (gene/thread/create (fn []
  (println "in thread"))))
(gene/thread/start t)
(gene/thread/join t)

# With return value
(var result (await (spawn_return (+ 100 23))))
# result => 123
```

### Message Passing
```gene
(gene/thread/send thread message)
```

Only "literal" values can be sent between threads:
- **Allowed**: primitives, arrays, maps, Gene values (with literal contents)
- **Not allowed**: functions, classes, instances, threads, futures, namespaces

### Thread Limits
- Maximum 64 threads (IDs 0-63)
- Each thread gets its own VM and message channel

---

## Potential Improvements

- **Structured concurrency**: No built-in way to manage groups of futures (wait-all, wait-any, cancellation). Must manually track and await each.
- **Cancellation**: Futures cannot be cancelled once started. A cooperative cancellation mechanism would prevent wasted work.
- **Timeouts**: No built-in `(await-with-timeout future ms)`. Must implement manually with racing futures.
- **`async for`**: No async iteration protocol. Cannot `for` over a stream of async values.
- **Thread safety of shared state**: No mutex, lock, or atomic primitives in the language. Shared mutable state across threads is unsafe.
- **Channel type**: Message passing uses thread-specific send. A first-class Channel type (like Go channels) would enable more flexible concurrent patterns.
- **Thread pool**: The 64-thread limit is fixed. A work-stealing thread pool would better utilize resources.
- **Promise/resolve pattern**: No way to create a future and resolve it externally (manual promise). Only `async` blocks produce futures.
- **Async in constructors/methods**: Async works in functions but the interaction with class constructors and method dispatch may have edge cases.
- **Event loop visibility**: The internal polling interval (every 100 instructions) is not configurable and not visible to users.
