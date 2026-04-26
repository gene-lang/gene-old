## Why
Pattern matching semantics were historically implicit, and stale planning still described a standalone `(match [pattern] value)` expression. The current compiler removes that surface, so this change should define the already-implemented argument/destructuring baseline without reopening the removed form.

## What Changes
- Define the minimal scope of pattern matching around argument binding, existing `var` destructuring, simple `case/when`, and enum ADT `case` patterns.
- Document the performance constraint for argument binding: no aggregate object is constructed just to bind parameters.
- Document scope/shadowing and arity/type error expectations for the Beta subset.
- Explicitly mark `(match ...)` as Removed/Future; use `(var pattern value)` for binding and `(case ...)` for branching.
- Keep map destructuring, nested patterns, guards, or-patterns, as-patterns, and full pattern-language work out of this baseline.

## Impact
- Affected specs: pattern-matching
- Affected code: matcher parsing/runtime binding, argument binder helpers, diagnostics, documentation/tests
