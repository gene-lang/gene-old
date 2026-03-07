# Selector Design Document

## Overview

Gene relies on a single `Value` type that can represent maps, arrays, genes, namespaces, classes, instances, and primitives. Selectors are the ergonomic layer that lets user code read, update, and delete arbitrarily nested structures without boilerplate. This document captures what exists today, what is missing, and the design direction needed to make selectors a first-class strength of the language.

## Goals

- **Universal Access**: Uniform syntax to read from any composite value (map, array, gene props/children, namespace, class, instance) and to chain access across nested structures.
- **Graceful Missing Values**: Distinguish between "present but empty" (`nil`) and "absent" (`void`) so callers can recover or escalate as needed.
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
  ```

- **Callable path segments (transform)**
  A selector path can include a function segment (usually created with `fn`). The function receives the currently matched value and its return value is passed to the next segment. The return value is **not** automatically written back into the parent container; use `$set` (and future `$set`) for assignment-style updates. In-place mutation is still possible when the matched value is a mutable container.
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

Once `*` or `**` has turned the pipeline into selection-mode, subsequent **normal path segments** are applied element-wise (i.e. the pipeline implicitly maps over the current selection). This yields the "map array children, process" behavior without requiring an explicit `(map ...)`.

Default end-of-selector reduction:
- If selector execution ends while in **value-stream** mode, the result is automatically collected to an array (equivalent to appending a trailing `@`).
- If selector execution ends while in **entry-stream** mode, the result is an array of `[key value]` pairs unless an explicit `@@` is used to collect into a map.

Missing values in selection-mode behave like "no match":
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
- **Multi-segment update/delete**: There is no generalized `selector_update`, `selector_delete`, or `$set`/`$del` API yet.
- **Generator integration**: Selectors cannot consume generators lazily. The `*` operator requires a materialized array/gene; it should also pull from generators via the iteration protocol.
- **`for` loop iteration protocol**: `for` currently uses index-based array access (`IkGetChildDynamic`). It cannot iterate over generators, maps (key-value), selector streams, or any user-defined iterable.

---

## Unified Iteration Protocol

Generators, selectors, `for` loops, and future lazy sequences all need a shared iteration contract. Without one, each feature reinvents traversal and they cannot compose.

### The Protocol

Any value that responds to `.iter` is **iterable**. Calling `.iter` returns an **iterator** — an object with:

| Method | Returns | Meaning |
|--------|---------|---------|
| `.next` | value or `NOT_FOUND` | Pull the next value. `NOT_FOUND` means exhausted. |
| `.next_pair` | `[key value]` or `NOT_FOUND` | Pull the next key-value pair (for entry iteration). |
| `.has_next` | bool | Peek without consuming (optional, for convenience). |

`NOT_FOUND` is the exhaustion sentinel (already used by generators). `void` is a valid yielded value, not exhaustion.

### Built-in Iterables

| Type | `.iter` behavior | `.next` yields | `.next_pair` yields |
|------|-----------------|----------------|---------------------|
| Array | index-based iterator | elements in order | `[index element]` |
| Map | entry iterator | values in insertion order | `[key value]` |
| Gene | children iterator | children in order | `[index child]` |
| Gene (props) | entry iterator over props | prop values | `[key value]` |
| Namespace | member iterator | member values | `[name value]` |
| Generator | returns self (generators are their own iterators) | yielded values | yielded `[k v]` pairs if the generator yields them |
| Selector stream | wraps the stream as an iterator | stream elements | stream entries |
| Range | lazy counter | numbers in range | `[index number]` |
| String | character iterator | characters | `[index char]` |

### Generator as Iterator

Generators already implement the right interface: `.next` returns values, `NOT_FOUND` signals exhaustion. A generator **is** its own iterator — calling `.iter` on a generator returns itself.

```gene
(fn counter* [max]
  (var i 0)
  (while (< i max)
    (yield i)
    (i = (+ i 1))))

# Generator works directly with for
(for x in (counter* 5)
  (println x))
# Output: 0 1 2 3 4
```

### `for` Loop Unification

The `for` loop compiles to the iteration protocol rather than hard-coded index access:

#### Value iteration: `(for x in iterable ...)`

```
compiled as:
  $iter = (iterable .iter)
  loop:
    $val = ($iter .next)
    if $val == NOT_FOUND: break
    x = $val
    ...body...
```

#### Destructuring iteration: `(for [k v] in iterable ...)`

```
compiled as:
  $iter = (iterable .iter)
  loop:
    $pair = ($iter .next_pair)
    if $pair == NOT_FOUND: break
    k = $pair/0
    v = $pair/1
    ...body...
```

#### Examples

```gene
# Iterate over map entries
(var m {^a 1 ^b 2 ^c 3})
(for [k v] in m
  (println k "=" v))
# a=1  b=2  c=3

# Iterate over array with index
(var arr ["x" "y" "z"])
(for [i val] in arr
  (println i ":" val))
# 0:x  1:y  2:z

# Iterate over generator key-value pairs
(fn entries* [m]
  (for [k v] in m
    (yield [k v])))

(for [k v] in (entries* {^x 10 ^y 20})
  (println k "->" v))

# Iterate over gene children
(var g (gene Type ^a 1 "child1" "child2"))
(for child in g
  (println child))
# child1  child2

# Iterate over gene props
(for [k v] in (g .:$props)
  (println k "=" v))
# a=1
```

#### Compilation Changes

The current `compile_for` in `control_flow.nim` uses `$for_collection`, `$for_index`, `IkLen`, and `IkGetChildDynamic`. The new compilation should:

1. Emit `IkGetIterator` on the collection value (calls `.iter`)
2. At loop top, emit `IkIterNext` (calls `.next` or `.next_pair` depending on binding pattern)
3. Check for `NOT_FOUND` and jump to end
4. Bind values to loop variables (reuse existing destructuring for `[k v]` patterns)
5. Remove `$for_index` / `IkLen` / `IkGetChildDynamic` — the iterator handles all state

New VM instructions:
- `IkGetIterator` — call `.iter` on TOS, push iterator
- `IkIterNext` — call `.next` on iterator, push value (or `NOT_FOUND`)
- `IkIterNextPair` — call `.next_pair` on iterator, push `[k v]` (or `NOT_FOUND`)

For arrays and other indexed types, the VM can fast-path `IkGetIterator` to create an internal index-based iterator that avoids the overhead of method dispatch, keeping `for` loops over arrays as fast as today.

### Selector ↔ Iterator Integration

#### Selectors Consume Iterables

The `*` expansion operator should work on any iterable, not just arrays/genes:

```gene
# * expands a generator lazily
(fn users* []
  (yield {^name "Ada"})
  (yield {^name "Grace"}))

(@*/name (users*))
# => ["Ada" "Grace"]

# * expands a range
(@*/.to_s (range 1 4))
# => ["1" "2" "3"]
```

Implementation: when `*` encounters a value that is not an array or gene, it calls `.iter` and pulls values via `.next`, feeding each into the remaining selector pipeline. This makes selectors lazy-compatible — a generator is never fully materialized unless the selector collects with `@`.

#### `**` Expands Entry-Iterables

Similarly, `**` should call `.next_pair` on any iterable that supports it:

```gene
# ** over a generator that yields entries
(fn config_entries* [files]
  (for f in files
    (var cfg (parse_config f))
    (for [k v] in cfg
      (yield [k v]))))

((@ ** (fn [k v] [k (normalize v)]) @@) (config_entries* file_list))
```

#### Selectors Produce Iterators

Selector streams should be consumable as iterators, not just auto-collected:

```gene
# Get a lazy iterator from a selector instead of collecting
(var name_iter (@*/name .iter users))

# Use in for loop
(for name in (@*/name users)
  (println name))

# Pipe selector output into another selector
(var active_names
  (@*/name
    (@*/?active users)))  # ? is predicate filter (see below)
```

### Generator ↔ Selector Composition Patterns

```gene
# Generator producing values, selector transforming them
(fn load_records* [db query]
  (var cursor (db .execute query))
  (while (cursor .has_next)
    (yield (cursor .next))))

# Select nested fields from generator output
(var names (@*/user/name (load_records* db "SELECT * FROM orders")))

# Generator consuming selector results
(fn summarize* [data]
  (for item in (@*/entries data)
    (yield {^key item/key ^total (sum item/values)})))

# Full pipeline: generate → select → generate → collect
(var report
  (@*/total
    (summarize* large_dataset)))
```

---

## Missing Features — Full Design

### 1. Range and Slice Selectors

Select multiple indices from arrays/genes:

```gene
# Range: indices 0 through 2 (inclusive)
((@ (0 .. 2)) arr)            # => [arr/0 arr/1 arr/2]

# Negative indices
((@(-3 .. -1)) arr)          # => last 3 elements

# List of specific indices
((@ [0 2 4]) arr)           # => [arr/0 arr/2 arr/4]
(arr .@ [0 2 4])


Ranges and slices enter **value-stream mode** (like `*`), so subsequent segments apply element-wise:

```gene
((@ (0 .. 2) "name") users)     # => [users/0/name users/1/name users/2/name]
```

### 2. Predicate Filtering (`?`) - deferred!

A `?` segment filters the current stream by a predicate function. Only values where the predicate returns truthy pass through:

```gene
# Filter array elements
(@*/?active users)
# equivalent to: select users where .active is truthy

# With inline predicate function
(@*/?(fn [u] (> u/age 18)) users)

# Filter entries
(@**/?[fn [k v] (starts_with k "user_")] config)

# Chained filters
(@*/?active/?verified users)
```

`?` in value-stream mode calls `pred(value)`.  
`?` in entry-stream mode calls `pred(key, value)`.  
Falsy results are skipped (the value does not appear in the stream).

Shorthand: `?field` is sugar for `?(fn [x] x/field)` — filters by truthiness of a nested field.

### 3. Gene-Specific Selectors

Special segments starting with `:$` access gene structure:

| Selector | Returns | Stream mode |
|----------|---------|-------------|
| `:$type` | The gene's type value | value |
| `:$props` | The gene's properties map | value (use `**` after to expand) |
| `:$children` | The gene's children array | value (use `*` after to expand) |
| `:$keys` | Property keys as array | value |
| `:$values` | Property values as array | value |

```gene
# Get gene type
(@/$type gene_val)           # => the type symbol

# Iterate props
(@/$props/**/@ gene_val)     # => [[k1 v1] [k2 v2] ...]
```

### 4. Mutation and Transformation APIs

Build on `$set` with composable mutation helpers:

```gene
# $set — apply a function to a selected value
($set user @profile/name (fn [n] (uppercase n)))

# $del — delete a selected key/index
($del config @deprecated_settings)

# Multi-segment mutation
($set tree @children/*/score (fn [s] (+ s 10)))
```

All mutation helpers share the selector traversal engine. For multi-segment paths, the engine walks to the parent container, then applies the operation (set/remove) at the final segment.

---

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
   - **Selectors consume any iterable** via the unified iteration protocol — `*` and `**` call `.iter`/`.next`/`.next_pair` on non-array/gene values.

4. **Mutation and Transformation APIs**
   - Add primitives like `$set`, `$del` that compose selectors with callbacks.
   - Ensure mutations respect immutability expectations when applied to persistent data structures (e.g., genes) or clone on write where necessary.

5. **Iteration Protocol First**
   - Implement the shared iteration protocol (`IkGetIterator`, `IkIterNext`, `IkIterNextPair`) before adding more selector features.
   - Refactor `compile_for` to use the protocol instead of index-based access.
   - Make generators iterable (`.iter` returns self).
   - Make arrays, maps, genes, namespaces, ranges, and strings iterable.
   - This unblocks both `for` loops over generators and selector expansion of generators.

6. **Testing Strategy**
   - Activate the commented tests in `tests/test_selector.nim` once the features exist.
   - Create focused suites for each selector capability (access, traversal, mutation, error modes) to keep regression coverage clear.

## Next Steps

1. **Define and implement the iteration protocol** (`IkGetIterator`, `IkIterNext`, `IkIterNextPair`).
2. Refactor `compile_for` to use the iteration protocol — support `(for x in ...)` and `(for [k v] in ...)` over all iterables.
3. Make generators iterable (`.iter` returns self, already has `.next`).
4. Wire `*` and `**` in `Selector.call` to consume iterables via the protocol.
5. Add tests for `**`, `@`, `@@`, callable entry transforms, and `!` in stream mode.
6. Implement range/slice selectors and predicate filtering (`?`).
7. Add gene-specific selectors (`:$type`, `:$children`, `_`).
8. Design mutation helpers for multi-segment selector paths.
9. Iterate on performance once the feature set stabilizes.

## Implementation Priority

### Phase 0: Unified Iteration Protocol (foundation for everything else)

1. **Define the protocol**
   - Add `Iterable` trait: any value responding to `.iter` → returns an iterator.
   - Add `Iterator` interface: `.next` → value or `NOT_FOUND`, `.next_pair` → `[k v]` or `NOT_FOUND`.
   - Generators already satisfy the iterator interface; add `.iter` returning `self`.

2. **Built-in iterators**
   - `ArrayIterator` — index-based, wraps existing array access.
   - `MapIterator` — entry-based, iterates insertion order.
   - `GeneChildIterator` — iterates gene children.
   - `GenePropIterator` — iterates gene props as `[key value]`.
   - `NamespaceIterator` — iterates namespace members.
   - `RangeIterator` — lazy counter for `(range start end [step])`.
   - `StringIterator` — character-by-character.

3. **New VM instructions**
   - `IkGetIterator` — call `.iter` on TOS, push iterator.
   - `IkIterNext` — call `.next` on iterator, push result.
   - `IkIterNextPair` — call `.next_pair` on iterator, push result.

4. **Refactor `compile_for`**
   - Replace `$for_collection` / `$for_index` / `IkLen` / `IkGetChildDynamic` with `IkGetIterator` / `IkIterNext` / `IkIterNextPair`.
   - Detect `(for [k v] in ...)` pattern → use `IkIterNextPair`.
   - Detect `(for x in ...)` → use `IkIterNext`.
   - Keep array fast-path: `IkGetIterator` on arrays creates an internal indexed iterator (no method dispatch overhead).

### Phase 1: Selector ↔ Iterator Integration

1. **`*` consumes iterables**
   - In `Selector.call`, when `*` encounters a non-array/gene value, call `.iter` and pull via `.next`.
   - Lazy: values are pulled one at a time and fed into the next selector segment.

2. **`**` consumes entry-iterables**
   - When `**` encounters a non-map/gene value, call `.iter` and pull via `.next_pair`.

3. **Selector streams as iterators**
   - Allow converting a selector stream result to an iterator instead of auto-collecting.
   - This enables `(for x in (@*/name users) ...)` without materializing the intermediate array.

### Phase 2: Correctness Guardrails

- Introduce `void` propagation in `IkGetMemberOrNil`/`IkGetMemberDefault` and update `$set` to surface meaningful errors when a path is missing.
- Expand `tests/test_selector.nim` to cover nil vs void behaviour so regressions are caught early.

### Phase 3: Range

- Implement range selectors `(@ (0 .. 2))`, and list selectors `(@ [0 2 4])`.
- VM opcodes for multi-value selection.

### Phase 4: Gene Introspection & Map Key Patterns

- Deliver `:$type`, `:$children`, `:$props`, `:$keys`, `:$values`

### Phase 5: Mutation & Transformation APIs

- `$set`, `$del`.
- Build on native selector traversal so all multi-segment paths share one implementation.
- Respect persistent data semantics (clone on write where needed).

### Phase 6: Higher-Order Operators & Performance

- Profile selector-heavy and iterator-heavy workloads.
- Cache repeated lookups, consider dedicated bytecode for common patterns.
- Document best practices and performance pitfalls.
