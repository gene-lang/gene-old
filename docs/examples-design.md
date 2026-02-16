# Function Examples Spec (`^examples` + `gene run-examples`)

## 1. Overview
This spec defines executable examples attached to function definitions and a CLI command to run them.

Goals:
- Keep examples close to the function they document.
- Make examples executable as validation checks.
- Provide clear pass/fail output suitable for local development and CI.

## 2. `^examples` Syntax on `fn`

### 2.1 Allowed location
`^examples` is a function property on `fn` definitions.

Example:
```gene
(fn add [a b]
  ^examples [ [1 2] -> 3
              [3 4] -> 7 ]
  (a + b)
)
```

### 2.2 Allowed example forms
Each example entry SHALL be one of:

1. **Result expectation**
```gene
[args...] -> expected_result
```

2. **Wildcard result expectation**
```gene
[args...] -> _
```
`_` means: any non-exception return value is accepted.

3. **Exception expectation**
```gene
[args...] throws ExceptionType
```
Example:
```gene
(fn positive_only [a]
  ^examples [ [1] -> _
              [-1] throws Exception ]
  (if (a <= 0) (throw Exception))
)
```

### 2.3 Validation rules
For each example entry:
- `args...` SHALL be an array literal.
- `->` form SHALL include exactly one expected expression (`expected_result` or `_`).
- `throws` form SHALL include exactly one exception type expression.
- Invalid example syntax SHALL be reported as a specification error before execution.

## 3. Runtime Semantics

For each function example:
1. Call the function with the provided argument array.
2. Evaluate outcome:
- **`-> expected_result`**: pass iff returned value equals `expected_result` using normal Gene value equality semantics.
- **`-> _`**: pass iff function returns normally (no exception).
- **`throws ExceptionType`**: pass iff function throws an exception whose runtime class matches `ExceptionType` (same type or subtype).

Failure conditions:
- Returned when `throws` expected.
- Threw when normal result expected.
- Returned value mismatch for `-> expected_result`.
- Threw wrong exception type for `throws ExceptionType`.

## 4. `gene run-examples` Command

### 4.1 Command
```bash
gene run-examples <file.gene>
```

### 4.2 Behavior
The command SHALL:
1. Load and compile `<file.gene>`.
2. Discover all function definitions in the module namespace that have `^examples`.
3. Execute all examples for each discovered function.
4. Print per-example pass/fail lines and a final summary.
5. Exit non-zero when any example fails.

Suggested exit codes:
- `0`: all examples passed
- `1`: one or more examples failed
- `2`: load/compile/spec error (invalid file or invalid `^examples` syntax)

If no functions with `^examples` are found, command SHOULD print:
```text
No examples found in <file.gene>
```
and exit `0`.

## 5. Reporting Format

### 5.1 Per-example success
```text
PASS <function_name> example <index>: <example_source>
```

### 5.2 Per-example failure
```text
FAIL <function_name> example <index>: <example_source>
  expected: <expected_outcome>
  actual: <actual_outcome>
  location: <file>:<line>
```

Where:
- `<expected_outcome>` is one of:
  - `return <value>`
  - `any return` (for `_`)
  - `throws <ExceptionType>`
- `<actual_outcome>` is one of:
  - `return <value>`
  - `throws <ExceptionType>: <message>`

### 5.3 Final summary
```text
Examples run: <total>, passed: <passed>, failed: <failed>, functions: <function_count>
```

## 6. Examples

### 6.1 Pure return checks
```gene
(fn add [a b]
  ^examples [ [1 2] -> 3
              [3 4] -> 7 ]
  (a + b)
)
```

### 6.2 Wildcard success + throws
```gene
(fn positive_only [a]
  ^examples [ [1] -> _
              [-1] throws Exception ]
  (if (a <= 0) (throw Exception))
)
```

## 7. Non-goals (for this iteration)
- Property-level examples on methods/classes.
- Snapshot/golden-file outputs.
- Fuzzy numeric tolerance.
- Parallel example execution.
