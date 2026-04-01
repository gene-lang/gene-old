# 12. Pattern Matching & Destructuring

## 12.1 Array Destructuring

```gene
(var [x y] [10 20])
# x => 10, y => 20
```

### With Rest
```gene
(var [first rest...] [1 2 3 4])
# first => 1, rest => [2, 3, 4]
```

## 12.2 Gene Value Destructuring

```gene
(var payload `(payload ^a 10 ^x 99 20 30 40))
(var [^a ^extra... first rest...] payload)
# a => 10
# first => 20 (first child)
# rest => [30, 40]
# extra => {^x 99} (remaining properties)
```

## 12.3 `case` / `when`

### Value Matching
```gene
(case day
  when 1 (println "Monday")
  when 2 (println "Tuesday")
  else   (println "Other"))
```

### ADT Pattern Matching
```gene
(var r (Ok 42))
(case r
  when (Ok v)  (println "Got:" v)
  when (Err e) (println "Error:" e))
```

### Option Matching
```gene
(var o (Some "hello"))
(case o
  when (Some x) (println x)
  when None     (println "none"))
```

### Wildcard
```gene
(case result
  when (Ok _)  (println "success")
  when (Err _) (println "failure"))
```

### Return Value
`case/when` is an expression — each branch returns a value:
```gene
(var doubled
  (case (Ok 10)
    when (Ok n) (n * 2)
    when (Err e) -1))
# doubled => 20
```

## 12.4 Destructuring in `for`

With arrays, `for i x` gives index + value:
```gene
(for i x in ["a" "b" "c"]
  (println i "=" x))
# Prints:
# 0 = a
# 1 = b
# 2 = c
```

With generators that yield pairs, `for k v` destructures each yielded pair:
```gene
(fn pairs* []
  (yield [0 2])
  (yield [1 3]))

(for k v in (pairs*)
  (println k "=" v))
# Prints:
# 0 = 2
# 1 = 3
```

## 12.5 `?` Operator (Early Return)

Unwraps `Ok`/`Some`, returns early on `Err`/`None`:

```gene
(fn increment [r: (Result Int String)] -> (Result Int String)
  (var v (r ?))    # Returns Err early if r is Err
  (Ok (v + 1)))

(increment (Ok 4))       # => (Ok 5)
(increment (Err "boom")) # => (Err "boom")
```

Works with Option too:
```gene
(fn double [o: (Option Int)] -> (Option Int)
  (var v (o ?))    # Returns None early if o is None
  (Some (v * 2)))

(double (Some 7))  # => (Some 14)
(double None)      # => (None)
```

---

> **Note:** The ADT pattern matching and `?` operator features (sections 12.3 ADT/Option/Wildcard, 12.5) are experimental and may undergo complete redesign.

## Potential Improvements

- **Nested patterns**: Pattern matching does not support nested structures like `(Ok [a b])` or `{^user {^name n}}`.
- **Guard clauses**: No `when (Ok v) if (v > 0)` guard syntax. Must use nested `if` inside the branch.
- **Exhaustiveness checking**: The compiler does not verify that all ADT variants are covered. Missing branches silently return nil.
- **Map destructuring**: `(var {^x a ^y b} map_value)` is not fully supported. Must access keys individually.
- **Pattern matching in function params**: Cannot use patterns directly in function signatures, e.g., `(fn f [(Ok v)] ...)`.
- **`match` expression**: `case/when` is the only pattern matching form. A more powerful `match` with richer patterns would be valuable.
- **Or-patterns**: Cannot match multiple patterns in one arm: `when (1 | 2 | 3)`.
- **As-patterns**: Cannot bind the whole value while also destructuring: `when (Ok v) as result`.
- **Scope safety**: Array destructuring has known scope issues — no `ScopeStart`/`ScopeEnd` pairing, potential for scope leaks.
- **Arity validation**: Out-of-bounds destructuring indices bind as nil without error. Should at least warn.
