# 9. Error Handling & Contracts

## 9.1 Try / Catch / Finally

```gene
(try
  (risky_operation)
catch *
  (println "Error:" $ex))
```

- `catch *` catches **all** exceptions
- `$ex` references the caught exception within the catch block
- `$ex` has a `.message` property

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

`finally` always executes, whether or not an exception occurred.

### Important: Always use `catch *`

Do not name the exception variable in catch:
```gene
# WRONG — causes panic on macOS
(try ... catch e ...)

# CORRECT
(try ... catch * (println $ex))
```

## 9.2 Throw

```gene
(throw "something went wrong")
(throw error_value)
```

Any value can be thrown. String values become the exception message.

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

- **Named catch bindings**: `catch *` is the only working form. Named bindings (`catch e`) should work to avoid the global `$ex` pattern.
- **Exception types/classes**: No typed exceptions. Cannot selectively catch specific exception types. Must catch all and inspect.
- **Multiple catch clauses**: Cannot have `catch TypeError ... catch ValueError ...` — only `catch *`.
- **Exception chaining**: No built-in way to wrap an exception with additional context (e.g., "failed to load config: file not found").
- **Stack traces**: Exception stack traces are limited. Improved trace formatting with source locations would aid debugging.
- **`with` / resource management**: No RAII or `with` statement for automatic resource cleanup. `finally` works but requires manual boilerplate.
- **Contract error messages**: Contract failures don't include which condition failed or the actual values. Better diagnostics would help.
- **Invariants**: Class invariants (checked after every method) are partially designed but not fully implemented.
- **`assert` vs contracts**: The relationship between `(assert cond)` and `^pre`/`^post` is unclear. Consider unifying or clearly differentiating.
