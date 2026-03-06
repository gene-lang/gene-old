# Selector Design Document

## Overview

Gene relies on a single `Value` type that can represent maps, arrays, genes, namespaces, classes, instances, and primitives. Selectors are the ergonomic layer that lets user code read, update, and transform arbitrarily nested structures without boilerplate. This document captures what exists today, what is missing, and the design direction needed to make selectors a first-class strength of the language.

## Goals

- **Universal Access**: Uniform syntax to read from any composite value (map, array, gene props/children, namespace, class, instance) and to chain access across nested structures.
- **Graceful Missing Values**: Distinguish between “present but empty” (`nil`) and “absent” (`void`) so callers can recover or escalate as needed.
- **Inline Mutation**: Pair selectors with simple update utilities so that modifying nested data feels natural.
- **Composable Transformations**: Make it easy to feed selector results into higher-order functions, predicate filters, and transformation pipelines.
- **Native Map/Reduce Pipelines**: Make it natural to select many values, transform them, and fold/collect results (CSS/XPath/XSLT-style).

## Current Implementation

### Syntax Supported Today

- **Path access via infix `/`**  
  Examples: `m/x`, `arr/0`, `arr/-1`. The compiler rewrites these into prefix calls that emit `IkGetMemberOrNil`. Array indices accept positive and negative integers. Other keys are coerced to strings/symbols before lookup.

- **Strict not-found assertion `/!`**
  `.../!` throws if the current selector value is `void` (missing). This can appear mid-path (`a/!/b`) or at the end (`a/b/!`).

- **Selector call `./`**  
  Form: `(target ./ key [default])`. Compiles with `compile_selector` and executes using `IkGetMemberOrNil` or `IkGetMemberDefault`. Behaves like a function so it can be partially applied or embedded in macros.

- **Selector literals and shorthand**  
  `(@ "name")`, `(@ "a" "b")`, `@a/b`, `@0/name`, and `@users/*/name` all compile to selector values (`VkSelector`). The shorthand path is split on `/` during compilation, and numeric / special segments are preserved as selector segments rather than normal symbol lookups.

- **Selector method shorthand**  
  Selectors can be applied as an object method:
  ```gene
  (data .@users/0/name)
  (data .@ "users" 1 "name")
  ```
  These compile to the `@` method on `Object`, which constructs a selector and immediately applies it to the receiver.

- **Selection-mode token segments**  
  Inside selector paths, the following segments are implemented today:
  - `*` expands array items or gene children into a value stream
  - `**` expands map / namespace / class / instance / gene props into an entry stream
  - `@` collects the current stream into an array value
  - `@@` collects an entry stream into a map
  - `!` asserts that the current selector result is not missing / empty

- **Shorthand for `$set`**  
  `$set` accepts selector shorthand such as `@prop` or `@0`. During compilation the shorthand is expanded to the `(@ ...)` form. Only a single property/index is supported today.

- **Updates through `$set`**  
  `$set target selector value` forwards to `IkSetMember` or `IkSetChild` (for arrays/genes). This enables simple nested mutation:  
  ```gene
  (var user {^profile {^name "Ada"}})
  ($set user @profile  {^name "Ada Lovelace"})
  ($set user @profile {^name "Ada L."})
  ```

- **Callable path segments (transform)**  
  A selector path can include a function segment (usually created with `fn`). The function receives the currently matched value and its return value is passed to the next segment. The return value is **not** automatically written back into the parent container; use `$set` (and future `$update`) for assignment-style updates. In-place mutation is still possible when the matched value is a mutable container.  
  ```gene
  (var data {^a 1})
  ((@ "a" (fn [item] (item + 1))) data)   # returns 2, does not change data/a
  ((@ "test" "x" 1 (fn [v] (v + 1))) {^test {^x [0 10 20]}})  # returns 11
  ```

### Runtime Semantics

- Selector literals are runtime values of kind `VkSelector`. They are callable through `Selector.call`, rather than being special-cased at every call site.
- `IkGetMemberOrNil` is the workhorse instruction for plain `/` access. It accepts string/symbol/int selectors and returns `void` when the key/index is missing. Arrays support negative indexing. Gene properties, namespace members, class static members, and instance properties are all handled.
- `IkGetMemberDefault` mirrors the above but takes a default value. The compiler emits it automatically when a third argument is present in `(./ target key default)`.
- `IkSetMember` and `IkSetChild` perform mutation for string/symbol keys and integer indices respectively.
- `IkAssertValue` is the runtime primitive backing plain `/!` path assertions. Selector-literal `!` checks are handled inside `Selector.call`.
- `Selector.call` has three execution modes:
  - value mode: a single current value
  - value-stream mode: multiple values produced by `*`
  - entry-stream mode: key/value pairs produced by `**`
- In stream modes, subsequent normal selector segments are applied element-wise. At the end of evaluation:
  - value streams are collected into arrays
  - entry streams are collected into arrays of `[key value]` pairs unless `@@` is used
- Callable selector segments are executed directly by the runtime:
  - in value mode: `fn(value)`
  - in entry mode: `fn(key, value)`
- Missing values are skipped in stream mode. A default argument to `Selector.call` is used when the final result is empty / missing.

## Current Selection-Mode Behavior

Selectors already support a basic match-many pipeline.

- `(@ users * name)` means:
  - lookup `users`
  - expand array items
  - lookup `name` on each item
  - collect the results into an array

Examples:

```gene
# Nested map/array traversal via shorthand
(@users/*/name data)

# Explicit selector literal form
((@ "users" "*" "name") data)

# Entry-stream transform, then collect back to map
((@ props ** (fn [k v] [k (f v)]) @@) target)
```

Supported token operators today:
- `*` (**expand children**)  
  Converts an array / gene into a stream of individual child values.
  - On arrays: expands elements
  - On genes: expands children
  - On other types: produces an empty stream

- `**` (**expand entries**)  
  Converts a keyed container into a stream of `[key value]` pairs.
  - On maps: expands entries
  - On genes: expands props entries (equivalent to `:$props`)
  - On namespaces: expands members
  - On classes: expands static members
  - On instances: expands instance properties
  - On other types: produces an empty stream

- `@` (**collect values**)  
  Collects the current stream of values into an array and switches back to value-mode.

- `@@` (**collect entries**)  
  Collects the current stream of `[key value]` pairs into a map and switches back to value-mode.

Once `*` or `**` has turned the pipeline into selection-mode, subsequent **normal path segments** are applied element-wise (i.e. the pipeline implicitly maps over the current selection). This yields the “map array children, process” behavior without requiring an explicit `(map ...)`.

Default end-of-selector reduction:
- If selector execution ends while in **value-stream** mode, the result is automatically collected to an array (equivalent to appending a trailing `@`).
- If selector execution ends while in **entry-stream** mode, the result is an array of `[key value]` pairs unless an explicit `@@` is used to collect into a map.

Missing values in selection-mode behave like “no match”:
- `void` is skipped when processing streams of values or pairs (it does not appear in collected output).
- Use `/!` when you want to assert that at least one match exists (throws if the current value is `void` in value-mode, or if the current stream is empty in selection-mode).

## Future Direction

Selectors are useful today, but they are still missing the pieces needed for full CSS/XPath-style querying. The next design layer should build on the existing `VkSelector` + `Selector.call` model rather than replace it.

## Tests Exercising the Implementation

`tests/test_selector.nim` contains the active coverage:
- `m/x` and `arr/idx` for maps and arrays.
- `./` for map lookup with and without default.
- Invocation of `(@ "prop")` and multi-segment selector literals.
- Shorthand selectors such as `@a/b`, `@0/name`, and `@users/*/name`.
- Selector method shorthand such as `(data .@users/0/name)` and `(data .@ "users" 1 "name")`.
- Selection-mode behavior with `*`.

The existing tests show that shorthand selectors and stream-style expansion are already part of the current surface area, not just future plans.

## Gaps and Missing Features

- **Range, slices, and list selectors**: Index ranges (`(0 .. 2)`), lists (`@ [0 1]`), and composite selectors are commented out in tests and lack compiler/VM support.
- **Map key patterns and property lists**: Regex/prefix matches, selecting multiple keys at once, and retrieving keys/properties as collections are unimplemented.
- **Gene-specific views**: Accessors for type, props, keys, values, children, and descendants (`:$type`, `:$children`, `_`, etc.) exist only in the design notes.
- **Predicate filtering**: Callable segments can transform values, but there is no dedicated predicate/filter selector operator yet.
- **Selector query API**: There is no separate `Selector.query` / match-first vs match-all API surface; everything routes through `Selector.call`.
- **Higher-order selector operators**: There is no native `(map ...)`, `(filter ...)`, or `(reduce ...)` selector operator syntax. Current behavior relies on `*`, `**`, callable segments, and implicit stream mapping.
- **Mutation breadth**: `$set` handles only direct property/index assignment. There is no support for appending, removing, or mutating collections returned by composite selectors.
- **Multi-segment update/delete**: There is no generalized `selector_update`, `selector_delete`, or `$update`/`$remove` API yet.

## Design Direction

1. **Absence Semantics**
   - Keep the current distinction: `nil` is data, `void` is selector miss.
   - Keep `(./ target key default)` and `Selector.call(... default)` returning the default when the final result is missing / empty.
   - Consider an `error_on_no_match` flag or explicit function when callers want hard failures.

2. **Selector Expression Grammar**
   - Formalize the grammar for ranges, list selectors, predicates, and descendant operators.
   - Preserve current shorthand forms (`@a/b`, `@0/name`, `@users/*/name`) as the base grammar rather than treating them as legacy syntax.

3. **Execution Model**
   - Keep selectors as compact runtime values and continue delegating traversal to `Selector.call`.
   - Extend the existing stream-mode execution with predicates, descendant traversal, and richer query flags rather than introducing a second selector engine.
   - Add native helpers like `selector_update`, `selector_delete`, and `selector_insert` for multi-segment mutation paths.

4. **Mutation and Transformation APIs**
   - Add primitives like `$update`, `$remove`, and `$transform` that compose selectors with callbacks.
   - Ensure mutations respect immutability expectations when applied to persistent data structures (e.g., genes) or clone on write where necessary.

5. **Testing Strategy**
   - Activate the commented tests in `tests/test_selector.nim` once the features exist.
   - Create focused suites for each selector capability (access, traversal, mutation, error modes) to keep regression coverage clear.

## Next Steps

1. Add tests for `**`, `@`, `@@`, callable entry transforms, and `!` in stream mode.
2. Implement ranges and list selectors.
3. Add namespace/gene specific selectors (`:$type`, `:$children`, descendants).
4. Design mutation helpers for multi-segment selector paths.
5. Iterate on performance once the feature set stabilizes; selector-heavy code should remain fast thanks to the bytecode VM.

Selectors are central to making Gene feel fluid when manipulating nested data. By closing these gaps and committing to `void` semantics, we can deliver an access and transformation system that matches the flexibility promised by the language’s generic value model.

## Implementation Priority

1. **Correctness Guardrails**
   - Introduce `void` propagation in `IkGetMemberOrNil`/`IkGetMemberDefault` and update `$set` to surface meaningful errors when a path is missing.
   - Expand `tests/test_selector.nim` to cover nil vs void behaviour so regressions are caught early.

2. **Selector Surface Clean-up**
   - Implement range and list selectors for arrays (`(0 .. 2)`, `@ [0 1]`) alongside VM opcodes that can return multiple values.
   - Expand tests/docs around the already-supported shorthand forms and stream operators.

3. **Namespace & Gene Introspection**
   - Deliver the planned built-ins like `:$type`, `:$children`, `_`, and key/value selectors so gene manipulation patterns become expressive.
   - Provide helper selectors for namespaces/classes (e.g. grabbing static members or instance props) to keep behaviour consistent.

4. **Selector Modes & Predicates**
   - Define selector modes (match-first vs match-all, error-on-miss) and carry them through new selector data structures.
   - Add predicate support (fn filters) and descendant traversal to unblock search-style selectors.

5. **Mutation & Transformation APIs**
   - Extend `$set` with `append`, `update`, `remove`, and higher-order transformation hooks, ensuring we respect persistent data semantics.
   - Offer a pipeline API that pairs selectors with callbacks, allowing transformations to be declared succinctly.
   - Build `$update`, `$remove`, and related helpers on top of the native selector functions (`selector_update`, `selector_delete`, etc.) so all multi-segment paths (`@a/b`) share one traversal implementation while still supporting different operations.

6. **Performance Pass**
   - Profile selector-heavy workloads, cache repeated lookups, and consider dedicated bytecode for common patterns once functionality stabilises.
   - Document best practices and potential pitfalls so users can write efficient selector code.
