# How Exceptions Work in Gene Today

This document describes the current exception model in the runtime as implemented
today.

The short version is:

- Gene has a runtime exception class called `Exception` with a hierarchy of
  subclasses (e.g. `TypeException`, `RuntimeException`, `IOError`).
- Every `throw` normalizes the thrown value into an `Exception` instance at the
  throw boundary via `normalize_exception`.
- The VM stores the active thrown value in `VM.current_exception`.
- `$ex` in catch blocks gives the Exception instance itself.
- `catch` accepts an Exception class, an array of classes, or `*`.
- Futures persist failures in their `value` slot.
- Cross-thread transport cannot carry exception instances directly, so thread
  failures are downgraded to a serializable error map and rewrapped on the
  receiving side.

## 1. Two exception layers

There are two related but distinct layers in the implementation.

### Gene-level exception class hierarchy

During app initialization, the runtime creates a built-in class named
`Exception`, stores it in `App.app.exception_class`, and adds it to the
global namespace. A legacy alias `Exception` also points to the same class.

The runtime also creates a hierarchy of exception subclasses:

- `RuntimeException` — division by zero, stack overflow, integer overflow
- `TypeException` — type mismatches, unsupported operations
- `ArgumentException` — invalid arguments, missing required params
- `IOError` — file not found, read/write failures
- `TimeoutException` — timeout errors
- `CancellationException` — async cancellation
- `ConcurrencyException` — thread/concurrency errors (parent: `RuntimeException`)

These are registered in the global namespace during `init_exception_hierarchy`.

Relevant implementation:

- `src/gene/types/helpers.nim` — `init_exception_hierarchy`, `normalize_exception`,
  `unwrap_exception_value`, `infer_exception_class`, `wrap_nim_exception`
- built at init time in `init_app_and_vm()`

### Host-side Nim exception carrier

The host runtime also defines a Nim exception type:

```nim
Exception* = object of CatchableError
```

in `src/gene/types/type_defs.nim`.

This is used for native control flow at the Nim boundary. The main execution
path uses `VM.current_exception` instead.

## 2. How Gene exceptions are created

### A. App bootstrap creates the base class and hierarchy

`init_app_and_vm()` allocates the built-in `Exception` class and its subclasses:

- `App.app.exception_class`
- `global_ns["Exception"]`
- `global_ns["TypeException"]`, `global_ns["RuntimeException"]`, etc.

### B. `throw` normalizes all values to Exception instances

The compiler lowers:

```gene
(throw expr)
```

by compiling `expr` and emitting `IkThrow`.

If no expression is provided, it pushes `nil` and still emits `IkThrow`.

At execution time, `IkThrow` calls `normalize_exception(raw_value)` which
wraps any non-Exception value into an Exception instance:

- **String throw** `(throw "msg")`: creates Exception with `message = "msg"`
- **Non-string throw** `(throw [1 2])`: creates Exception with
  `message = "[1 2]"` and `cause = [1 2]`
- **Nil throw** `(throw)`: creates Exception with `message = "nil"`
- **Existing Exception instance**: returned as-is

This means `VM.current_exception` always holds an Exception instance (or
subclass) after a throw.

### C. Native/runtime failures are wrapped via `wrap_nim_exception`

Many native helpers do:

```nim
raise new_exception(types.Exception, "message")
```

or call `not_allowed(...)`, which does the same thing.

Those start as Nim `CatchableError`s. When they escape into the VM execution
loop, the runtime converts them into a Gene exception value via
`wrap_nim_exception(...)`.

`wrap_nim_exception(...)` uses `infer_exception_class` to pick the most
specific subclass based on message content, then creates an instance with:

- `message`
- `nim_type`
- `nim_stack`
- `location`

For example, a Nim error containing "type error" becomes a `TypeException`
instance; one containing "division by zero" becomes a `RuntimeException`.

### D. Async helpers create exception instances directly

`src/gene/vm/async.nim` defines `new_async_error(...)`, which directly creates
an Exception instance with properties such as:

- `code`
- `message`
- `location`

This is used for timeout, cancellation, and async callback failure paths.

### E. Some subsystems define their own error classes

Examples:

- `TestFailure` extends `Exception` in `src/genex/test.nim`

## 3. Where the active exception is stored

The active exception is stored on the VM:

- `VM.current_exception`

There is also:

- `VM.repl_exception`

which is used when the REPL temporarily takes over after an error.

This is the central runtime storage.

## 4. How `throw` is dispatched at runtime

At execution time, `IkThrow`:

1. pops the thrown value from the stack
2. calls `normalize_exception(raw_value, location)` to wrap it
3. calls `dispatch_exception(value, inst)`

`dispatch_exception(...)` then:

1. stores the value in `self.current_exception`
2. checks for AOP context escape
3. checks whether there is an active exception handler (respecting
   `exec_handler_base_stack` boundaries)
4. for async block handlers (`CATCH_PC_ASYNC_BLOCK`): captures the exception
   in a failed future, clears `current_exception`, skips to after `IkAsyncEnd`
5. for async function handlers (`CATCH_PC_ASYNC_FUNCTION`): captures in a
   failed future, clears `current_exception`, returns to caller frame
6. for normal catch handlers: unwinds frames and scopes back to the handler's
   saved state, jumps execution to the catch PC
7. if no handler exists: formats the exception and raises a host Nim exception

## 5. How catch blocks receive the exception

### `$ex` gives the Exception instance

When catch code refers to `$ex`, `gene/ex`, or `global/ex`, the VM resolves
from:

- `VM.current_exception` if set
- otherwise `VM.repl_exception`

The value is the Exception instance itself (not unwrapped). To access the
original message, use `($ex .message)`.

### Catch patterns

`catch` accepts three forms:

- `catch *` — catch all exceptions
- `catch SomeException` — catch a specific Exception subclass
- `catch [ExceptionA ExceptionB]` — catch any of several Exception subclasses

Typed catches work by:

1. reading `gene/ex`
2. calling `IkGetClass`
3. comparing it against the requested class using `IkIsInstance`

## 6. How `finally` interacts with exceptions

`finally` uses `current_exception` as the rethrow source.

The VM:

1. enters the finally block
2. preserves normal result values when needed
3. leaves `current_exception` intact if an exception is in flight
4. after finally cleanup, rethrows by redispatching the saved exception value

So the exception survives `finally` by staying in `VM.current_exception`, not by
being copied into a separate wrapper structure.

## 7. How unhandled exceptions leave the VM

At the end of execution, if:

- `current_exception != NIL`
- and there are no remaining handlers

the VM raises a host Nim exception using a formatted message.

Formatting goes through `format_runtime_exception(...)`, which:

- walks the class hierarchy to check if the value is an Exception instance
  (including subclasses like `TypeException`)
- extracts `message` from the Exception instance when possible
- otherwise stringifies the thrown value
- wraps plain messages into the diagnostic envelope format (JSON with
  `code`, `message`, `severity`, `stage`, `span`, `hints`, `repair_tags`)

This is the point where a Gene-thrown value becomes a CLI-visible error string.

## 8. How futures store exceptions

`FutureObj` has:

- `state`
- `value`

The `value` field stores either:

- the success result
- the failure payload (the Exception instance)
- the cancellation reason

When `await` sees:

- `FsSuccess`: it pushes `future.value`
- `FsFailure`: it copies `future.value` into `current_exception` and throws
- `FsCancelled`: it uses the stored cancellation value or synthesizes an async
  error instance, then throws that

When an async block catches an exception (`CATCH_PC_ASYNC_BLOCK`), the
exception is captured into a failed future and `current_exception` is cleared.
This prevents the `IkEnd` instruction from re-raising an already-handled
exception.

## 9. How threads store and pass exception-like failures

Threads are different because payloads crossing threads must be literal
serializable.

`serialize_literal(...)` explicitly rejects non-literal values such as:

- functions
- classes
- instances
- threads
- futures

That means a real Exception instance cannot be shipped directly across
thread boundaries.

### Thread request/reply path

For thread replies:

1. the sender stores a pending `FutureObj` in `vm.thread_futures`
2. the worker thread computes a result
3. if successful, it serializes the literal reply payload
4. if it fails, it sends a special map payload:

```gene
{^__thread_error__ true ^message "..."}
```

5. the receiving side detects that marker with `thread_error_message(...)`
6. it converts the failure into a new async error instance with
   `new_async_error(...)`
7. that new instance is stored in the waiting future as the failure payload

So across threads, the original exception object is not preserved. The system
passes a serialized error description and reconstructs a new local exception
value on the receiving VM.

## 10. REPL-on-error behavior

REPL-on-error temporarily moves the active exception into `repl_exception`,
clears `current_exception`, runs the REPL, then restores the old state.

If the REPL throws a new exception, that new value is copied back into
`current_exception` after cleanup.

This is why `$ex` still works inside the REPL session opened at an error site.

## 11. Practical mental model

If you want the current implementation model in one sentence:

> Every Gene throw normalizes the thrown value into a structured Exception
> instance. `$ex` in catch blocks gives the Exception instance itself.
> `VM.current_exception` acts as the live transport slot inside the VM.

That breaks down into:

1. `Exception` is the built-in structured exception class with a hierarchy of
   subclasses.
2. `throw` normalizes any value into an Exception instance at the boundary.
3. `VM.current_exception` is the active in-flight exception store.
4. `$ex` gives the Exception instance itself; use `($ex .message)` for the
   message string.
5. `catch` accepts an Exception class, an array of classes, or `*`.
6. futures persist failures in `FutureObj.value`.
7. async exception capture clears `current_exception` to prevent double-raise.
8. threads cannot preserve exception instances, so they serialize error data and
   reconstruct a new local error value.

## 12. File map

Core files for the current implementation:

- `src/gene/types/helpers.nim` — app init, `Exception` hierarchy,
  `normalize_exception`, `infer_exception_class`, `wrap_nim_exception`
- `src/gene/types/type_defs.nim` — `VirtualMachine`, `FutureObj`, host
  `Exception`
- `src/gene/compiler/control_flow.nim` — `throw`, `try`, `catch`, `finally`
- `src/gene/vm/exceptions.nim` — exception dispatch, unwinding, async capture
- `src/gene/vm/exec.nim` — instruction execution, `IkThrow`, `await`, unhandled
  exception exit path, `$ex` resolution
- `src/gene/vm/runtime_helpers.nim` — exception formatting (with subclass-aware
  message extraction) and thread worker reply behavior
- `src/gene/vm/async.nim` — async error creation and future callbacks
- `src/gene/vm/async_exec.nim` — thread reply polling and thread error
  rewrapping
- `src/gene/repl_session.nim` — REPL-on-error exception preservation

## Summary

The exception model has two key layers:

1. **Normalization at throw**: `normalize_exception` ensures every thrown value
   becomes an Exception instance with structured fields (`message`, `cause`,
   `location`). Nim exceptions are wrapped via `wrap_nim_exception` with
   subclass inference.

2. **Internal transport**: `VM.current_exception` always holds an Exception
   instance. Dispatch, finally rethrow, and future capture all operate on this
   structured representation. `$ex` exposes the Exception instance directly to
   user code.

That is the exception model the rest of the runtime currently builds on.
