# 12. Pattern Matching & Destructuring

Gene currently has a tested destructuring subset plus several experimental
pattern-matching ideas. Treat the stable subset below as the contract; anything
outside it remains subject to redesign.

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
no-match `case` without `else` returns `nil`.

## Experimental and downstream subset

Enum ADT variant matching is part of the unified enum work, but it is not part of the stable pattern contract yet. The downstream goal is to match enum variants through enum metadata, bind payload fields in declaration order, and eventually provide exhaustiveness diagnostics.

The future enum shape is expected to resemble:

```gene
(case result
  (when (Ok value) value)
  (when (Err error) error)
  (when Empty nil))
```

This is an enum-variant pattern direction, not a revival of legacy Gene-expression ADT matching. The matcher must not depend on hardcoded `Ok`, `Err`, `Some`, or `None` expression names as a second ADT model.

The `?` operator remains tied to the Result/Option migration and is not promoted to stable pattern semantics by this section.

## Known gaps

- Enum variant patterns, enum field destructuring, and enum exhaustiveness diagnostics are not stable yet.
- Nested patterns beyond currently covered destructuring are not stable.
- Guard clauses such as `when pattern if condition` are not supported.
- Map destructuring syntax such as `(var {^x a ^y b} value)` is not stable.
- Function-parameter patterns beyond the existing argument matcher surface are
  not specified as a general pattern system.
- `match`, or-patterns, and as-patterns are not implemented.
- Broad arity diagnostics are incomplete; some destructuring failures still
  report low-level matcher errors.
