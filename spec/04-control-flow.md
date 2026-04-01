# 4. Control Flow

## 4.1 `if` / `elif` / `else`

```gene
(if (x > 20)
  (println "big")
elif (x == 20)
  (println "equal")
else
  (println "small"))
```

- `then` keyword is optional after the condition
- `elif` chains additional conditions
- `else` is optional
- Returns the value of the taken branch

## 4.2 `while`

```gene
(var n 0)
(while (n < 10)
  (n += 1))
```

## 4.3 `loop` / `break` / `continue`

Infinite loop, exited with `break`:

```gene
(var i 0)
(loop
  (if (i >= 5) then (break))
  (i += 1))
```

`break` can return a value:

```gene
(var result (loop
  (if done then (break 42))
  (next_step)))
# result => 42
```

`continue` skips to next iteration:

```gene
(loop
  (if (skip_this) then (continue))
  (process))
```

## 4.4 `for`

Iterates over collections and generators:

```gene
# Array iteration - value only
(for x in [1 2 3 4]
  (println x))

# Array iteration - index + value
(for i x in [10 20 30]
  (println i ":" x))        # 0:10  1:20  2:30

# Map iteration - key + value
(for k v in {^a 1 ^b 2}
  (println k "=" v))

# Map iteration - key + destructured value
(for k [a b] in {^x [1 2] ^y [3 4]}
  (println k ":" a "," b))

# Generator iteration
(fn counter* [n]
  (var i 0)
  (while (i < n)
    (yield i)
    (i += 1)))
(for x in (counter* 5)
  (println x))
```

## 4.5 `repeat`

Execute body a fixed number of times:

```gene
(repeat 3
  (println "hello"))
```

## 4.6 `case` / `when`

Pattern-based dispatch:

```gene
# Value matching
(case day
  when 1 (println "Monday")
  when 2 (println "Tuesday")
  when 3 (println "Wednesday")
  else   (println "Other"))

# ADT pattern matching
(var r (Ok 42))
(case r
  when (Ok v)  (println "Got:" v)
  when (Err e) (println "Error:" e))
```

See [Pattern Matching](12-patterns.md) for full details.

## 4.7 `return`

Early return from a function:

```gene
(fn find_first [arr pred]
  (for x in arr
    (if (pred x) then (return x)))
  nil)
```

---

## Potential Improvements

- **`for` range syntax**: No built-in `(for i in (range 0 10))` or `(for i from 0 to 10)`. Must use generators or while loops for numeric ranges.
- **`match` expression**: `case/when` handles simple patterns. A full `match` expression with nested patterns, guards, and exhaustiveness checking would be more powerful.
- **Exhaustiveness checking**: `case/when` does not verify that all variants of an ADT are covered. Missing branches silently return nil.
- **Loop labels**: No way to break out of nested loops. Use `^name` on the loop and `^from` on break/continue: `(loop ^name outer ... (break ^from outer 42))`, `(continue ^from inner)`. Works on all loop forms (`loop`, `while`, `for`). Implementation: add optional `name` field to `LoopInfo`, check `gene.props["name"]` in compile_loop/while/for, scan `loop_stack` by name in compile_break/continue.
- **Early break from `for`**: `break` inside `for` exits the for loop, but returning a value from `for` is not clearly specified.
