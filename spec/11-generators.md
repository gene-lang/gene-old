# 11. Generators

## 11.1 Generator Functions

Generator functions produce values lazily via `yield`. They are defined with a `*` suffix:

```gene
(fn counter* [n]
  (var i 0)
  (while (i < n)
    (yield i)
    (i += 1)))
```

## 11.2 Using Generators

### Manual Iteration
```gene
(var gen (counter* 3))
gen/.next     # => 0
gen/.next     # => 1
gen/.next     # => 2
gen/.next     # => NOT_FOUND (exhausted)
```

### `for` Loop Integration
```gene
(for x in (counter* 5)
  (println x))
```

### Check Exhaustion
```gene
gen/.has_next   # true if more values available
```

## 11.3 Anonymous Generator Functions

Use the `^^generator` flag:

```gene
(var squares
  (fn ^^generator [max]
    (var i 0)
    (while (i < max)
      (yield (i * i))
      (i += 1))))

(for x in (squares 4)
  (println x))   # 0, 1, 4, 9
```

## 11.4 Iterator Protocol

Generators implement the iterator protocol:

- `.iter` — returns self
- `.next` — returns next value or `NOT_FOUND`
- `.has_next` — peek without consuming

Any object implementing these methods works with `for`.

## 11.5 Destructuring in `for`

```gene
(fn pairs* [m]
  # yields [key, value] pairs from a map
  ...)

(for [k v] in (pairs* my_map)
  (println k "=" v))
```

---

## Potential Improvements

- **Generator delegation (`yield*`)**: No way to delegate to another generator. Must manually iterate and re-yield.
- **Generator return values**: Generators return `NOT_FOUND` on exhaustion. No way to return a final value (like Python's `StopIteration.value`).
- **Bidirectional generators**: Cannot send values into a generator (like Python's `gen.send(value)`). Generators are pull-only.
- **Infinite generators and safety**: No built-in take/drop/limit combinators. Easy to accidentally consume an infinite generator in a `for` loop.
- **Generator composition**: No built-in way to chain, zip, or transform generators without materializing into arrays first.
- **Async generators**: No way to yield async values. Would need `async fn*` and `for await` patterns.
- **Anonymous generator syntax**: The `^^generator` flag is non-obvious compared to the `*` suffix on named generators. Consider `(fn* [args] ...)` for consistency.
- **`NOT_FOUND` sentinel**: Using a sentinel value for exhaustion means `NOT_FOUND` cannot be yielded as a regular value. Consider a wrapper type or protocol-based exhaustion signal.
