# 12. Pattern Matching & Destructuring

Gene specifies a tested destructuring subset plus `case` matching for simple values and enum ADTs. Treat the stable subset below as the public contract; pattern forms listed under known gaps remain subject to redesign.

## Tested stable subset

### Array destructuring in `var`

```gene
(var [x y] [10 20])
# x => 10, y => 20
```

### Default values in destructuring patterns

```gene
(var [x = nil y = 2] [])
# x => nil, y => 2
```

An explicit `nil` default is distinct from "no default".

### Named positional rest

Exactly one named positional rest binding is supported:

```gene
(var [first rest...] [1 2 3 4])
# first => 1, rest => [2, 3, 4]
```

The postfix form is also accepted:

```gene
(var [items ... tail] [1 2 3 4])
# items => [1, 2, 3], tail => 4
```

### Gene property and child destructuring

Gene values can destructure properties and children:

```gene
(var payload `(payload ^a 10 ^x 99 20 30 40))
(var [^a first rest...] payload)
# a => 10
# first => 20
# rest => [30, 40]
```

### Gene property rest binding

Remaining Gene properties can be captured into a map:

```gene
(var payload `(payload ^a 10 ^x 99 20))
(var [^a first ^extra...] payload)
# a => 10
# first => 20
# extra => {^x 99}
```

### Simple value `case/when`

```gene
(case day
  when 1 "Monday"
  when 2 "Tuesday"
  else   "Other")
```

`case/when` is an expression; each selected branch returns its last value.
A no-match `case` without `else` returns `nil`.

### Enum ADT `case` patterns

Enum ADTs match through the canonical `enum` model. A `when` pattern can name a qualified variant (`Shape/Circle`) or a bare variant (`Circle`) when the bare name resolves unambiguously for the scrutinee. Use qualified names when variants share names across enums or when a custom enum uses built-in names such as `Ok`, `Err`, `Some`, or `None`.

```gene
(enum Shape
  (Circle radius)
  (Rect width height)
  Point)

(fn describe [shape: Shape] -> String
  (case shape
    when (Shape/Circle r)
      "circle"
    when (Shape/Rect w h)
      "rect"
    when Shape/Point
      "point"))
```

Payload binders are positional and follow the field declaration order. A binder must be a symbol. The special binder `_` consumes that payload position without creating a binding.

```gene
(var rect (Shape/Rect 10 20))
(println
  (case rect
    when (Shape/Rect _ height)
      height
    else
      0))
# => 20
```

Unit variants match as symbols, either qualified (`Shape/Point`) or bare (`Point`) when resolution is unambiguous. Payload variants must provide exactly one binder per declared payload field; missing or extra binders produce an arity diagnostic. Unknown enum or variant names produce diagnostics, and ambiguous bare variant names require qualification.

Built-in `Result` and `Option` variants are enum variants too. Bare `Ok`, `Err`, `Some`, and `None` patterns match the built-in enum identities; qualify user-defined same-named variants to match custom enums.

```gene
(case (Ok 42)
  when (Ok value)
    value
  when (Err error)
    error)
# => 42
```

A `case` over a statically known enum value is checked for exhaustiveness when it has no explicit `else` and no wildcard `_` branch. The exhaustiveness rule is strict about the enum declaration: every declared variant must be covered, and missing variants are reported in declaration order. At runtime, a `case` expression with no matching `when` and no `else` returns `nil`.

Legacy Gene-expression ADT matching is not a supported public model. Quoted or stale legacy Result/Option-shaped Gene values should be migrated to enum-backed values and matched with enum variant patterns.

## Known gaps

- Nested patterns beyond currently covered destructuring are not stable.
- Guard clauses such as `when pattern if condition` are not supported.
- Map destructuring syntax such as `(var {^x a ^y b} value)` is not stable.
- Function-parameter patterns beyond the existing argument matcher surface are
  not specified as a general pattern system.
- `match`, or-patterns, and as-patterns are not implemented.
- Broad arity diagnostics are incomplete for non-enum destructuring; some destructuring failures still
  report low-level matcher errors.
