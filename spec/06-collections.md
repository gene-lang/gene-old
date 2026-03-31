# 6. Collections

## 6.1 Arrays

### Literals and Access
```gene
(var arr [1 2 3])
arr/0              # => 1 (zero-indexed)
arr/-1             # => 3 (negative indexing from end)
(arr/0 = 99)       # Mutation
```

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
(cfg/port = 9090)  # Mutation
```

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

## 6.3 Gene Values (S-Expressions as Data)

Gene values are the homoiconic core — code and data share the same structure.

```gene
(var g `(Person ^name "Alice" ^age 30 "child1" "child2"))
g/.type        # => Person
g/.props       # => {^name "Alice" ^age 30}
g/.children    # => ["child1", "child2"]
```

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

## 6.4 Selectors

Selectors provide path-based data access:

```gene
# Selector literals
(@ "key")              # Single segment
(@ "a" "b" "c")       # Multi-segment: a/b/c

# Shorthand
@users/*/name          # Wildcard: all user names

# Stream operations
# * — expand array elements
# ** — expand map entries as [key, value]
# @ — collect stream into array
# @@ — collect stream into map
```

## 6.5 Immutability

Arrays, maps, and Gene values can be made immutable (details implementation-dependent).

---

## Potential Improvements

- **Persistent/immutable collections by default**: All collections are mutable. Immutable-by-default with explicit `mut` would improve safety and enable easier concurrency.
- **Set ergonomics**: A `Set` class exists in the runtime, but collection-oriented constructors and set algebra methods are still sparse compared with arrays and maps.
- **Tuple type**: No immutable fixed-size sequence. Arrays serve this role but are mutable and variable-length.
- **Collection comprehensions**: No list/map comprehension syntax. Must use `.map`/`.filter` chains or `for` loops.
- **Lazy sequences**: Arrays are fully materialized. Lazy sequences (beyond generators) would help with large data processing.
- **Selector error messages**: Selectors return `void` on missing keys, which can make debugging access chains difficult. Consider optional "strict mode" that throws on missing.
- **Destructuring in `for`**: Works for some cases but not all — e.g., nested destructuring in iteration is limited.
- **Slice syntax**: No dedicated array slice syntax like `arr[1..3]`; use methods such as `.slice` instead.
- **Sorted maps / ordered iteration**: Map iteration order is not guaranteed. An ordered map variant would be useful.
