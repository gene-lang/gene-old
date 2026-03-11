# Dynamic Selector Syntax Sugar for Gene

## Overview

Add `<>` syntax within path/selector expressions to mark segments as dynamically resolved, plus define semantics for the existing `./` and `@` operators in this context.

## Syntax Forms

### Static vs Dynamic Property Access

| Syntax | Meaning | Desugars to |
|--------|---------|-------------|
| `a/x` | Static property access (literal member `x`) | — |
| `a/<b>` | Dynamic property access (resolve `b`, use as selector) | `(a @ b)` |
| `a/<b/c>` | Dynamic with path (resolve `b/c` first, use result as selector) | `(a @ b/c)` |

### Static vs Dynamic Method Calls

| Syntax | Meaning |
|--------|---------|
| `a/.test` | Static method call, no args |
| `(a/.test arg1 arg2)` | Static method call with args |
| `a/.<b>` | Dynamic method call, no args (resolve `b` to get method name) |
| `(a ./ b arg1 arg2)` | Dynamic method call with args (operator form) |

### Mixed Static/Dynamic Paths

Static and dynamic segments can be combined:

```gene
a/x/<b>/y      # access a.x, then dynamic lookup, then .y
a/<b>/<c>      # two dynamic lookups chained
```

## Resolution Rules

The expression inside `<>` is resolved and must produce a valid selector:

- **Non-empty string** → internalized to symbol → used as key ✅
- **Integer** → used as index (array-like access) ✅
- **nil** → **TypeError** ❌
- **void** → **TypeError** ❌
- **Empty string `""`** → **TypeError** ❌
- **Any other type** → **TypeError** ❌

Map keys in Gene are symbols (internalized strings), so string results are converted to symbols for property lookup.

**Escape hatch:** For edge cases like empty-string keys, use explicit method call: `(map .get "")`

## Equivalences

```gene
a/<b>           ≡  (a @ b)       ≡  (a ./ b)
a/<b/c>         ≡  (a @ b/c)
a/.<b>          ≡  dynamic method call on a with method name from b (no args)
(a ./ b x y)   ≡  dynamic method call on a with method name from b, args x y
```

## Compiler Considerations

### Parsing `<>` Across Segments

The parser splits complex symbols on `/`, so `a/.<b/c>` is parsed into raw segments:

```
"a" / ".<b" / "c>"
```

The compiler must post-process these segments:

1. Scan segments for unmatched `<` — this opens a dynamic span
2. Accumulate segments until matching `>` is found
3. Reassemble the dynamic expression inside `<>` (e.g., `".<b"` + `"c>"` → dynamic method call with path `b/c`)
4. Convert the reconstructed form into the appropriate semantic representation

**Example:** `a/.<b/c>` raw segments → compiler recognizes `.<b/c>` as a single dynamic method segment → emits equivalent of `(a ./ b/c)` (dynamic method call, resolve `b/c` for method name).

### Content Inside `<>` Limited to Path Fragments

The `<>` form only supports path fragments (symbols, paths like `b/c`), **not** arbitrary expressions. For computed keys from expressions, use the operator form:

```gene
# Path fragment — works in <> sugar
a/<b/c>

# Arbitrary expression — use operator form
(a @ (pick key))
```

This avoids parser changes — the compiler just reassembles segments split on `/`.

### Dynamic Method Dispatch — Implementation Note

Currently `IkDynamicMethodCall` only supports instance receivers. Static method calls (`a/.test`) work on all value types (strings, arrays, maps) via the normal value-method dispatch path, but dynamic method calls do not.

**Required:** Dynamic dispatch must use the same unified dispatch path as static method calls, supporting any receiver type — strings, arrays, maps, instances, etc. Dynamic and static method calls should behave identically except for how the method name is determined (resolved vs literal).

## Design Notes

- `<>` inside paths means "resolve this segment" — consistent everywhere
- `.` prefix means "method" — consistent with existing `a/.test`
- Selector form (`a/<b>`, `a/.<b>`) for inline/no-arg usage
- Operator form (`(a ./ b ...)`) when args are needed (S-expression call)
- Error-by-default for invalid selector types keeps the mental model simple
- Empty string keys are valid in maps but rejected in selectors — use `(map .get "")` explicitly
