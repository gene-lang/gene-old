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
  Form: `(./ target key [default])`. Compiles with `compile_selector` and executes using `IkGetMemberOrNil` or `IkGetMemberDefault`. Behaves like a function so it can be partially applied or embedded in macros.

- **Selector literal `(@ "prop")`**  
  `compile_at_selector` wraps the property in a gene that the VM understands. When invoked like `((@ "name") user)` it desugars to `(./ user "name")`.

- **Shorthand for `$set`**  
  `$set` accepts selector shorthand such as `@prop` or `@0`. During compilation the shorthand is expanded to the `(@ ...)` form. Only a single property/index is supported today.

- **Updates through `$set`**  
  `$set target selector value` forwards to `IkSetMember` or `IkSetChild` (for arrays/genes). This enables simple nested mutation:  
  ```gene
  (var user {^profile {^name "Ada"}})
  ($set user @profile  {^name "Ada Lovelace"})
  ($set user @profile/name "Ada L.")
  ```

- **Callable path segments (transform)**  
  A selector path can include a function segment (usually created with `fn`). The function receives the currently matched value and its return value is passed to the next segment. The return value is **not** automatically written back into the parent container; use `$set` (and future `$update`) for assignment-style updates. In-place mutation is still possible when the matched value is a mutable container.  
  ```gene
  (var data {^a 1})
  ((@ a (fn [item] (item + 1))) data)   # returns 2, does not change data/a
  ((@ a (fn [item] (item .append 10) item)) data)  # mutates item in place
  ```

### Runtime Semantics

- `IkGetMemberOrNil` is the workhorse instruction. It accepts string/symbol/int selectors and returns `void` when the key/index is missing. Arrays support negative indexing. Gene properties, namespace members, class static members, and instance properties are all handled.
- `IkGetMemberDefault` mirrors the above but takes a default value. The compiler emits it automatically when a third argument is present in `(./ target key default)`.
- `IkSetMember` and `IkSetChild` perform mutation for string/symbol keys and integer indices respectively.
- `IkAssertNotVoid` throws if the current value is `void`. This is the runtime primitive backing `/!`.

## Recommendations: Map/Reduce as First-Class Selector Operators

To approach CSS selector + XPath query power, selectors need to support **match-many** queries and then **transform/aggregate** them. The recommended model is:

- Keep current `/`, `./`, `Selector.call` as **value-mode** (single value, missing → `void`).
- Add **selection-mode** APIs that return a collection of matches (possibly empty), and allow *operators* like map/reduce to run on that selection.

### 1) Selection Mode vs Value Mode

`void` is a great sentinel for “missing key/index/member” in value-mode, but it is awkward for match-many queries (where “no matches” should be an empty set).

Recommendation:
- `Selector.call(selector, target, [default])` → value-mode (existing)
- ``Selector.query(selector, target, ^mode `all|`first)`` → selection-mode (new)
  - ``^mode `all``: returns an array (empty when no matches)
  - ``^mode `first``: returns first match or `void`

This cleanly separates “missing member” (`void`) from “matched nothing” (`[]`).

### 2) Operator Segments: `(map ...)`, `(filter ...)`, `(reduce ...)`, `(collect)`

Define a small set of selector-specific operator segments:
- `(map fn)` → apply `fn` to each element of the current selection/array
- `(filter pred)` → keep elements where `pred` returns truthy
- `(reduce init fn)` → fold elements into an accumulator
- `(collect)` → normalize the current selection into an array (convenience; often the implicit final step in `query`)

Important semantic recommendation (to avoid surprises):
- A **callable segment** `(fn ...)` continues to mean “transform the current value”.
- A **map** operator is always explicit; we do not implicitly map just because the current value happens to be an array.

### 2.1) Token Operators: `*`, `**`, `@`, `@@`

For ergonomics (especially in selector-heavy code), we can introduce single-token operators as selector path segments:

- `*` (**expand children**)  
  Converts an array / gene into a stream of individual child values.
  - On arrays: expands elements
  - On genes: expands children (equivalent to `:$children`)
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

Pair representation:
- Entry streams are represented as 2-element arrays `[key value]`, so `@@` can rebuild a map deterministically (last write wins on duplicate keys).
- When mapping an entry stream with a callable segment, the callable is invoked as `fn(k, v)` (2 args). If it returns `[key value]`, both key and value are replaced; otherwise only the value is replaced and the key is preserved.

Syntax/compatibility notes:
- These token operators are intended to work **inside selector literals** like `(@ ... )`. Until the shorthand grammar is extended, forms like `@a/*/b/@` will be parsed as plain member lookups, not selector operators.
- `@@` currently looks like an `@`-prefixed symbol in normal code; outside selector literals it may be interpreted as selector shorthand by the compiler. Inside `(@ ... )` it is just a selector segment value.

### 2.2) Implicit Mapping in Selection Mode

Once `*` or `**` has turned the pipeline into selection-mode, subsequent **normal path segments** are applied element-wise (i.e. the pipeline implicitly maps over the current selection). This yields the “map array children, process” behavior without requiring an explicit `(map ...)`.

Default end-of-selector reduction (recommended):
- If selector execution ends while in **value-stream** mode, the result is automatically collected to an array (equivalent to appending a trailing `@`).
- If selector execution ends while in **entry-stream** mode, the result is an array of `[key value]` pairs unless an explicit `@@` is used to collect into a map.

Missing values in selection-mode should behave like “no match”:
- `void` is skipped when processing streams of values or pairs (it does not appear in collected output).
- Use `/!` when you want to assert that at least one match exists (throws if the current value is `void` in value-mode, or if the current stream is empty in selection-mode).

### 3) Example: Map Children and Reduce Into a Collection

```gene
# Select children, transform each, then reduce into an array accumulator.
# (acc .append v) returns acc, so it works well as a reducer.
((@ a :$children
    (map (fn [child] ...))
    (reduce [] (fn [acc v] (acc .append v)))
 ) target)
```

This pattern directly supports “map array children, process, then reduce to a collection at the end”.

Token-operator equivalent:

```gene
((@ a *               # expand children/items
    (fn [child] ...)  # transform each selected child
 ) target)
```

And for keyed collections:

```gene
((@ props **                  # stream [k v] pairs
    (fn [k v] [k (f v)])       # transform values (key is preserved unless you return [k v])
    @@                        # collect back into a map (otherwise you get an array of [k v])
 ) target)
```

### 4) Implementation Notes (for later)

- Start by supporting operators when the current value is a `VkArray` (low risk).
- Extend selection-mode once descendant traversal / `:$children` / `_` land.
- For performance, compile common operator chains into dedicated fast paths (avoid allocating intermediate arrays when `map → reduce` can stream).

## Tests Exercising the Implementation

`tests/test_selector.nim` contains the active coverage:
- `m/x` and `arr/idx` for maps and arrays.
- `./` for map lookup with and without default.
- Invocation of `(@ "prop")` and `$set` using `@` selectors.
- Negative array indices are covered indirectly inside the VM but not yet asserted via tests.

Many more scenarios are sketched but commented out, signalling the intended scope for selectors once features land.

## Gaps and Missing Features

- **Chained shorthand selectors**: Parsing for `@prop/child`, `@0/name`, `@.method`, `@*` aggregation, and composite selector lists is unfinished.
- **Range, slices, and list selectors**: Index ranges (`(0 .. 2)`), lists (`@ [0 1]`), and composite selectors are commented out in tests and lack compiler/VM support.
- **Map key patterns and property lists**: Regex/prefix matches, selecting multiple keys at once, and retrieving keys/properties as collections are unimplemented.
- **Gene-specific views**: Accessors for type, props, keys, values, children, and descendants (`:$type`, `:$children`, `_`, etc.) exist only in the design notes.
- **Predicate-based selectors**: There is no mechanism to pass a predicate function (`fn`) that filters descendants or siblings.
- **Selector flags and modes**: Concepts like `match-first` vs `match-all` and `error_on_no_match` are undefined beyond comments.
- **Transform pipelines**: We do not yet surface APIs to apply transformations or callbacks to selector matches (akin to CSS selectors + rules).
- **Selector collection operators**: There is no native selector support for `(map ...)`, `(filter ...)`, `(reduce ...)`, or `(collect)` over match sets.
- **Mutation breadth**: `$set` handles only direct property/index assignment. There is no support for appending, removing, or mutating collections returned by composite selectors.
- **Dedicated error handling**: Without `void` propagation and flags, callers must manually guard against `nil` and cannot distinguish “missing” from “present but empty”.

## Design Direction

1. **Absence Semantics**
   - Update `IkGetMemberOrNil` (and friends) to return `VOID` when a member/index is not found.
   - Keep `(./ target key default)` returning the default even if the target is `void`, so defaults stay predictable.
   - Consider an `error_on_no_match` flag or explicit function when callers want hard failures.

2. **Selector Expression Grammar**
   - Formalize the grammar for selectors: literals (`@`, `/`), composites (`@*`, `[ ... ]`), predicates, and descendant operators.
   - Extend the compiler’s desugaring logic to produce dedicated instructions or data structures instead of ad-hoc genes.

3. **Execution Model**
   - Distinguish strict vs tolerant path segments: intermediate segments use `IkGetMember` (which should raise on missing members once `void` semantics land) while the final segment uses `IkGetMemberOrNil` to provide a soft default.
   - Introduce an `IkAssertNotVoid` instruction emitted by suffix operators such as `!` (e.g. `x/a/!` compiles to `IkResolve x; IkGetMember a; IkAssertNotVoid`) so callers can opt into hard guarantees inline.
   - Represent `@...` selectors as compact values and delegate execution to a small set of native functions:
     - `selector_call(selector, target)` → perform the read traversal and return the value (used for `(@a/b) obj` and `/` shorthand).
     - `selector_update(selector, target, value)` → walk the path and assign the new value (used by `$set` and future `$update`).
     - `selector_delete(selector, target)` → remove the addressed member/index.
     - `selector_insert(selector, target, value)` → optional helper for collection inserts/appends when we need it.
   - The compiler only needs to emit the selector literal and call the appropriate native function; traversal logic stays centralized in Nim.
   - Introduce richer selector values (structs) that carry mode flags, predicate callbacks, and path steps.
   - Implement traversal in the VM that can handle match-all vs match-first, descendant searches, and predicate evaluation efficiently, possibly via iterators or generators.

4. **Mutation and Transformation APIs**
   - Add primitives like `$update`, `$remove`, and `$transform` that compose selectors with callbacks.
   - Ensure mutations respect immutability expectations when applied to persistent data structures (e.g., genes) or clone on write where necessary.

5. **Testing Strategy**
   - Activate the commented tests in `tests/test_selector.nim` once the features exist.
   - Create focused suites for each selector capability (access, traversal, mutation, error modes) to keep regression coverage clear.

## Next Steps

1. Ship `void` propagation and adjust tests to assert the distinction between `nil` and `void`.
2. Re-enable simple shorthand (`@prop/child`, ranges) and add VM support for composite selectors.
3. Document and implement namespace/gene specific selectors (`:$type`, `_`, descendants).
4. Design the API for selector-driven transformations and mutations, validating the ergonomics on real-world data structures.
5. Iterate on performance once the feature set stabilizes; selector-heavy code should remain fast thanks to the bytecode VM.

Selectors are central to making Gene feel fluid when manipulating nested data. By closing these gaps and committing to `void` semantics, we can deliver an access and transformation system that matches the flexibility promised by the language’s generic value model.

## Implementation Priority

1. **Correctness Guardrails**
   - Introduce `void` propagation in `IkGetMemberOrNil`/`IkGetMemberDefault` and update `$set` to surface meaningful errors when a path is missing.
   - Expand `tests/test_selector.nim` to cover nil vs void behaviour so regressions are caught early.

2. **Selector Surface Clean-up**
   - Fix the compiler/parser to support chained shorthand (`@foo/bar`) and update docs/tests accordingly.
   - Implement range and list selectors for arrays (`(0 .. 2)`, `@ [0 1]`) alongside VM opcodes that can return multiple values.

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
