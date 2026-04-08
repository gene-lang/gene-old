# 4. Control Flow

## 4.1 `if` / `elif` / `else`

```gene
(var x 20)
(if (x > 20)
  (println "big")
elif (x == 20)
  (println "equal")
else
  (println "small"))
# => equal
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
(println n)
# => 10
```

## 4.3 `loop` / `break` / `continue`

Infinite loop, exited with `break`:

```gene
(var i 0)
(loop
  (if (i >= 5) then (break))
  (i += 1))
(println i)
# => 5
```

`break` can return a value:

```gene
(var i 0)
(var result (loop
  (if (i == 2) then (break 42))
  (i += 1)))
(println result)
# => 42
```

`continue` skips to next iteration:

```gene
(var seen [])
(var i 0)
(loop
  (i += 1)
  (if (i == 2) then (continue))
  (seen .add i)
  (if (i >= 3) then (break)))
(println seen)
# => [1 3]
```

## 4.4 `for`

Iterates over collections and generators:

```gene
# Array iteration - value only
(for x in [1 2 3]
  (println x))

# Array iteration - index + value
(for i x in [10 20 30]
  (println [i x]))

# Map iteration - key + value
(for k v in {^a 1}
  (println [k v]))

# Map iteration - key + destructured value
(for k [a b] in {^x [1 2]}
  (println [k a b]))

# Generator iteration
(fn counter* [n]
  (var i 0)
  (while (i < n)
    (yield i)
    (i += 1)))
(for x in (counter* 3)
  (println x))
# => 1
# => 2
# => 3
# => [0 10]
# => [1 20]
# => [2 30]
# => [a 1]
# => [x 1 2]
# => 0
# => 1
# => 2
```

## 4.5 `repeat`

Execute body a fixed number of times:

```gene
(repeat 3
  (println "hello"))
# => hello
# => hello
# => hello
```

## 4.6 `case` / `when`

Pattern-based dispatch:

```gene
# Value matching
(var day 2)
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
# => Tuesday
# => Got: 42
```

See [Pattern Matching](12-patterns.md) for full details.

## 4.7 `return`

Early return from a function:

```gene
(fn find_first [arr pred]
  (for x in arr
    (if (pred x) then (return x)))
  nil)
(println (find_first [1 3 4 6] (fn [x] ((x % 2) == 0))))
# => 4
```

---

## Potential Improvements

- **Exhaustiveness checking**: `case/when` does not verify that all variants of an ADT are covered. Missing branches silently return nil.
- **Loop labels**: No way to break out of nested loops. Use `^name` on the loop and `^from` on break/continue: `(loop ^name outer ... (break ^from outer 42))`, `(continue ^from inner)`. Works on all loop forms (`loop`, `while`, `for`). Implementation: add optional `name` field to `LoopInfo`, check `gene.props["name"]` in compile_loop/while/for, scan `loop_stack` by name in compile_break/continue.
- **Early break from `for`**: `break` inside `for` exits the for loop, but returning a value from `for` is not clearly specified.
