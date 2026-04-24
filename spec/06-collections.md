# 6. Collections

## 6.1 Arrays

### Literals and Access
```gene
(var arr [1 2 3])
arr/0              # => 1 (zero-indexed)
arr/-1             # => 3 (negative indexing from end)
arr/99             # => void (out of range)
(arr/0 = 99)       # Mutation
```

Array lookup returns `void` for an out-of-range index. A present element whose
value is `nil` remains `nil`.

### Nested Access
```gene
(var matrix [[1 2] [3 4]])
matrix/1/0         # => 3
```

### Spread
```gene
(var left [1 2])
(var right [3 4])
(var both [left... right...])   # => [1, 2, 3, 4]
```

### Methods
```gene
arr/.size          # Element count
arr/.length        # Same as size
(arr .add 4)       # Append (mutates)
(arr .get 0)       # Index access
(arr .pop)         # Remove and return last
(arr .map (fn [x] (x * 2)))       # => [2, 4, 6]
(arr .filter (fn [x] (x > 1)))    # => [2, 3]
(arr .reduce 0 (fn [acc x] (acc + x)))  # => 6
```

## 6.2 Maps

### Literals and Access
```gene
(var cfg {^host "localhost" ^port 8080 ^ssl false})
cfg/host           # => "localhost"
cfg/missing        # => void
(cfg/port = 9090)  # Mutation
```

Map lookup returns `void` for a missing key. A present key whose value is `nil`
remains `nil`.

### Nested Maps
```gene
(var nested {^outer {^inner 123}})
nested/outer/inner  # => 123
```

### Shortcut Syntax
```gene
(var m {
  ^^a         # ^a true
  ^!b         # ^b false
  ^c^^d       # ^c {^d true}
  ^c^!e       # ^c {^e false} (merges into c)
  ^c^f 100    # ^c {^f 100}
})
```

### Methods
```gene
m/.size
(m .map (fn [k v] ...))
(m .filter (fn [k v] (v >= 90)))
(m .reduce init (fn [acc k v] ...))
```

### Assertion Access
```gene
cfg/host/!         # Returns value or throws if missing/nil
```

## 6.3 Ranges

Ranges are lazy numeric sequences. `(start .. end)` is inclusive with an implicit step of `1`. Use `(range start end step)` for stepped or descending ranges.

```gene
(println (0 .. 3))
(println (range 1 5 2))
(println (range 5 1 -2))
# => 0..3
# => 1..5 step 2
# => 5..1 step -2
```

### Iterators
```gene
(var it ((range 1 5 2) .iter))
(println (typeof it))
(println (it .has_next))
(println (it .next))
(println (it .next_pair))
(println (it .next))
(println (it .has_next))
# => RangeIterator
# => true
# => 1
# => [1 3]
# => 5
# => false
```

### `for` Loops
```gene
(for x in (range 1 5 2)
  (println x))
# => 1
# => 3
# => 5
```

## 6.4 Gene Values (S-Expressions as Data)

Gene values are the homoiconic core — code and data share the same structure.

```gene
(var g `(Person ^name "Alice" ^age 30 "child1" "child2"))
g/.type        # => Person
g/.props       # => {^name "Alice" ^age 30}
g/.children    # => ["child1", "child2"]
g/missing      # => void
g/99           # => void
```

Gene property lookup returns `void` for a missing property, and Gene child
lookup returns `void` for an out-of-range child index. Stored `nil` properties
and children remain `nil`.

### Gene Property Spread
```gene
(var attrs {^class "main" ^id "header"})
(`div ^... attrs "content")
# => (div ^class "main" ^id "header" "content")
```

### Gene Children Spread
```gene
(var items [1 2 3])
(`list items...)
# => (list 1 2 3)
```

## 6.5 Selectors (Overview)

Collections participate in Gene's selector system, but selectors are substantial enough to have their own section: see [17. Selectors](17-selectors.md).

Quick reminders:

```gene
user/name             # Path lookup
people/0/name         # Nested array + map access
@users/*/name         # Reusable selector value
(data .@users/0/name) # Method shorthand
```

## 6.6 Immutability

Arrays, maps, and Gene values can be made immutable (details implementation-dependent).

---

## Potential Improvements

- **Tuple type**: No immutable fixed-size sequence. Arrays serve this role but are mutable and variable-length.
- **Lazy sequences**: Arrays are fully materialized. Lazy sequences (beyond generators) would help with large data processing.
- **Selector error messages**: Selectors return `void` on missing keys, which can make debugging access chains difficult. Consider optional "strict mode" that throws on missing.
- **Slice syntax**: No dedicated array slice syntax like `arr[1..3]`; use methods such as `.slice` instead.
- **Sorted maps / ordered iteration**: Map iteration order is not guaranteed. An ordered map variant would be useful.
