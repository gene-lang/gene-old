# 9. Error Handling & Contracts

## 9.1 Try / Catch / Finally

```gene
(try
  (risky_operation)
catch *
  (println "Error:" $ex/message))
```

- `catch *` catches **all** exceptions
- `catch SomeException` catches only exceptions of type `SomeException` (or a subclass)
- `$ex` references the caught `Exception` instance within the catch block
- Access fields via `$ex/message`, `$ex/cause`, etc. (or method form `($ex .message)`)

### Catch by Type

```gene
(try
  (risky_operation)
catch IOError
  (println $ex/message))
```

Typed catches match against the built-in `Exception` class hierarchy (see 9.2). Subclass matching is inheritance-aware: `catch Exception` catches any subclass.

Multiple typed catch clauses can be chained — the first matching clause wins:

```gene
(try
  (risky_operation)
catch IOError
  (println "IO failed:" $ex/message)
catch ParseException
  (println "Parse failed:" $ex/message)
catch *
  (println "Unknown error:" $ex/message))
```

### Catch Forms

| Form | Behavior |
|------|----------|
| `catch *` | Match any exception; no binding (use `$ex`) |
| `catch SomeException` | Match by class (uppercase symbol); subclass-aware |
| `catch ex` | Match any exception and bind to local `ex` (lowercase symbol) |
| `catch _` | Match any exception; discard binding |
| `catch [a b]` / `catch {^x x}` | Match any exception; destructure the `Exception` instance |

Note: `$ex` is always available inside a catch block regardless of the form.

### With `finally`
```gene
(try
  (open_resource)
  (use_resource)
catch *
  (handle_error $ex)
finally
  (close_resource))
```

`finally` always executes, whether or not an exception occurred. An in-flight exception is preserved across `finally` and rethrown after cleanup if no catch clause handled it.

## 9.2 Throw

```gene
(throw "something went wrong")
(throw error_value)
(throw)  # rethrow / nil-throw
```

At the throw boundary, the VM normalizes every thrown value into an `Exception` instance:

- `(throw "msg")` → `Exception` with `message = "msg"`
- `(throw non_string)` → `Exception` with `message = (str non_string)` and `cause = non_string`
- `(throw existing_exception)` → passed through as-is
- `(throw)` → `Exception` with `message = "nil"`

Because of normalization, `$ex` inside a catch block is always an `Exception` (or subclass) instance.

### Exception Class Hierarchy

Gene provides a built-in exception class hierarchy, all rooted at `Exception`:

- `Exception` — root class
  - `RuntimeException` — division by zero, stack overflow, integer overflow
  - `TypeException` — type mismatches, unsupported operations
  - `ArgumentException` — invalid arguments, missing required params
  - `IOError` — file not found, read/write failures
  - `ParseException` — parse/syntax errors
  - `AssertionException` — failed `assert` / contract violations
  - `ConcurrencyException`
    - `TimeoutException`
    - `CancellationException`
    - `ThreadException`
  - `NetworkException`
  - `ProviderException`

All subclasses live in the global namespace. Native runtime failures are wrapped into the most specific subclass inferred from the error message. User code can extend the hierarchy via `(class MyError < Exception ...)`.

## 9.3 Preconditions

Validate inputs before function execution:

```gene
(fn positive_only [x: Int] -> Int
  ^pre [(x > 0)]
  x)

(positive_only 3)    # => 3
(positive_only -1)   # Throws precondition failure
```

## 9.4 Postconditions

Validate the result after function execution:

```gene
(fn increment [x: Int] -> Int
  ^post [(result > x)]
  (x + 1))
```

- `result` refers to the function's return value inside postconditions.

## 9.5 Method Contracts

Preconditions and postconditions also work on methods:

```gene
(class BankAccount
  (ctor [balance] (/balance = balance))
  (method withdraw [amount]
    ^pre [(amount > 0) (/balance >= amount)]
    ^post [(/balance >= 0)]
    (/balance = (/balance - amount))
    /balance))
```

## 9.6 Contract Control

Contracts can be disabled at runtime for performance.

---

## Potential Improvements

- **Exception chaining**: No first-class API to wrap an exception with additional context (e.g., "failed to load config: file not found"). The `cause` field is populated on non-string throws but there is no ergonomic wrap/rethrow helper.
- **Stack traces**: Exception stack traces are limited. Improved trace formatting with source locations would aid debugging.
- **`with` / resource management**: No RAII or `with` statement for automatic resource cleanup. `finally` works but requires manual boilerplate.
- **Contract error messages**: Contract failures don't include which condition failed or the actual values. Better diagnostics would help.
- **Invariants**: Class invariants (checked after every method) are partially designed but not fully implemented.
- **`assert` vs contracts**: The relationship between `(assert cond)` and `^pre`/`^post` is unclear. Consider unifying or clearly differentiating.
