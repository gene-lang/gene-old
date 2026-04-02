## Why
Positional rest binding is currently inconsistent across matcher parsing, runtime binding, and static typing. The codebase already suggests support for rest/splat-style patterns, but non-tail forms and standalone postfix `...` are not specified, which leads to ambiguous behavior and incorrect arity/type handling.

## What Changes
- Define positional rest binding syntax for function parameters and destructuring patterns.
- Specify deterministic binding semantics for a single named positional rest binder, including non-tail forms.
- Keep the runtime binder allocation-free with respect to aggregate argument objects and avoid backtracking-heavy matching.
- Define the corresponding type-system behavior so rest position is preserved instead of assuming the rest parameter is always last.
- Specify error handling for anonymous or multiply-declared positional rest binders.

## Impact
- Affected specs: `pattern-matching`, `type-system`
- Affected code: `src/gene/types/core/matchers.nim`, `src/gene/vm/args.nim`, `src/gene/type_checker.nim`, `tests/integration/test_pattern_matching.nim`, `tests/integration/test_keyword_args.nim`
