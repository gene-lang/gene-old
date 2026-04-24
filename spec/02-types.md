# 2. Types

## 2.1 Value Types

Gene uses a NaN-boxed 64-bit representation. Every value is one of the following kinds:

### Primitive Types
| Type    | Description                    |
|---------|--------------------------------|
| `Int`   | 48-bit signed integer          |
| `Float` | IEEE 754 double-precision      |
| `String`| UTF-8 string (heap-allocated)  |
| `Bool`  | `true` or `false`              |
| `Nil`   | The `nil` value                |
| `Void`  | Missing-result sentinel        |
| `Char`  | Single Unicode character       |
| `Symbol`| Interned identifier            |

### Composite Types
| Type        | Description                           |
|-------------|---------------------------------------|
| `Array`     | Ordered, mutable sequence             |
| `Map`       | Key-value pairs (symbol keys)         |
| `Gene`      | S-expression node (type + props + children) |
| `Function`  | First-class function/closure          |
| `Namespace` | Namespace scope                       |
| `Class`     | Class definition                      |
| `Instance`  | Class instance with properties        |
| `Future`    | Async computation result              |
| `Generator` | Lazy value producer                   |
| `Actor`     | Public message-passing concurrency handle |
| `Regex`     | Compiled regular expression           |
| `Range`     | Numeric range (lazy)                  |
| `Date`      | Calendar date                         |
| `DateTime`  | Date + time snapshot                  |
| `Bytes`     | Byte sequence                         |
| `Enum`      | Enumeration type                      |

### Nil and Void

`nil` is an explicit value for intentional absence and optional values.
`void` is the missing-result value produced when a lookup has no value to
return. Both are observable runtime outcomes, but they mean different things:
`nil` is data, while `void` reports that an access or match did not produce a
value.

Missing map keys, missing object or instance properties, missing Gene
properties, and out-of-range array or Gene child indices return `void`. Lookup
on a `nil` receiver propagates `nil`. Defaults on lookup operations replace
`void` lookup failure, not explicit `nil` values stored in the target.

A `case` expression with no matching `when` and no `else` returns `nil`.
Function bodies return their last expression, so optional-style functions
should return `nil` explicitly when they mean "no value".

### Range

Ranges are lazy numeric sequences. `(start .. end)` creates an inclusive range with step `1`; `(range start end step)` creates a stepped range.

```gene
(println (typeof (0 .. 3)))
(println (range 1 5 2))
# => VkRange
# => 1..5 step 2
```

### Date, DateTime, and Time

Date, DateTime, and Time are first-class literal types following ISO 8601, RFC 3339,
and RFC 9557 standards. Years must be 4 digits. Timezone abbreviations (EDT, PST) are
not supported — use IANA zone names or UTC offsets.

```gene
# Date literals
(var d 2024-01-23)
(println d)                              # => 2024-01-23
(println (d .year) (d .month) (d .day))  # => 2024 1 23

# DateTime literals
(println 2024-01-23T20:10)               # => 2024-01-23T20:10
(println 2024-01-23T20:10:10)            # => 2024-01-23T20:10:10
(println 2024-01-23T20:10:10.123)        # => 2024-01-23T20:10:10.123
(println 2024-01-23T20:10:10Z)           # => 2024-01-23T20:10:10Z
(println 2024-01-23T20:10:10+05:30[Asia/Kolkata])
                                         # => 2024-01-23T20:10:10+05:30[Asia/Kolkata]

# Time literals
(println 10:10)                          # => 10:10
(println 10:10:10.123)                   # => 10:10:10.123
(println 10:10:10Z)                      # => 10:10:10Z
(println 10:00[America/New_York])        # => 10:00[America/New_York]

# Accessors
(var dt 2024-01-23T20:10:10+05:30[Asia/Kolkata])
(println (dt .timezone))                 # => Asia/Kolkata
(println (dt .offset))                   # => 330

# Comparison
(println (< 2024-01-01 2024-12-31))      # => true
(println (> 10:30 10:00))                # => true
```

Stdlib functions: `gene/today`, `gene/now`, `gene/yesterday`, `gene/tomorrow`.

### Bytes

Byte sequences with three literal forms. Small values (1-6 bytes) are NaN-boxed
immediates (no heap allocation); larger values use heap storage. `0x` prefix is
reserved for hex integers.

```gene
# Literal forms
(println 0!11110000)              # => 0#f0      (binary)
(println 0#a0ff)                  # => 0#a0ff    (hex bytes)
(println 0*AQID)                  # => 0#010203  (base64)
(println 0xff)                    # => 255       (hex integer, NOT bytes)

# Accessors
(println (0#abcd .size))          # => 2
(println (0#abcd .get 0))         # => 171
(println (0#abcd .to_array))      # => [171 205]

# Equality
(println (== 0#ff 0#ff))          # => true

# String conversion
(println (typeof ("ABC" .bytes))) # => VkBytes
```

All byte values display as `0#` hex regardless of input format. `~` is a visual
separator in all three forms (ignored along with following whitespace).

## 2.2 Type Annotations

Annotations are optional (gradual typing). When present, they are checked at compile time.

```gene
# Variable
(var x: Int 10)

# Function parameters and return type
(fn add [a: Int b: Int] -> Int
  (a + b))

# Class field metadata consumed by the type checker
(class Point
  ^fields {^x Int ^y Int}
  (ctor [x: Int y: Int]
    (/x = x)
    (/y = y)))
```

`^fields` currently feeds compile-time type information for field access and assignment. It does not, by itself, imply runtime storage layout or runtime type enforcement.

## 2.3 Type Expressions

Types can be composed:

```gene
# Union types
(var x: (String | Nil) "hello")

# Type alias
(type DisplayLabel (String | Nil))

# Generic functions
(fn identity:T [x: T] -> T
  x)

# ADT (Algebraic Data Types)
(type (Result T E) ((Ok T) | (Err E)))
(type (Option T) ((Some T) | None))
```

## 2.4 Type Checking

```gene
# Runtime type check with `is`
(42 is Int)           # => true
("hi" is String)      # => true
(person is Person)    # => true

# `typeof` returns type name
(typeof 42)           # => Int
(typeof "hi")         # => String

# Type equivalence
(types_equivalent DisplayLabel `(Nil | String))  # => true
```

## 2.5 Built-in ADTs

Gene provides `Result` and `Option` types:

```gene
# Result
(var ok (Ok 42))
(var err (Err "bad"))

# Option
(var some (Some "hello"))
(var none None)

# Unwrap with ? operator (early return on Err/None)
(fn safe_div [a b]
  (if (b == 0) then (return (Err "div by zero")))
  (Ok (a / b)))

(fn compute []
  (var v ((safe_div 10 2) ?))   # Unwraps Ok, or returns Err
  (v * 3))
```

## 2.6 Enumerations

```gene
(enum Color red green blue)
Color/red     # Access member
```

---

## Potential Improvements

- **Generic classes**: Only generic functions are supported. Generic classes (`class Stack:T`) are not yet implemented.
- **Duration/Period arithmetic**: Date/time literals and comparisons are implemented, but arithmetic (adding durations, computing date differences) is not yet supported.
- **Bytes operations**: Byte literals and basic accessors (`.size`, `.get`, `.to_array`) are implemented. Bitwise operations, `.slice`, `.concat`, and bytes-to-string conversion are not yet available.
- **Type bounds/constraints**: No way to express `T: Comparable` or similar constraints on generic type parameters.
- **Inference completeness**: Type inference still falls back to `Any` in some complex binding positions, notably destructuring parameters and other non-trivial patterns.
- **Union type narrowing**: Flow-sensitive narrowing works in `if` branches and ADT-aware `case/when` arms, but not in every control-flow form or arbitrary predicate.
- **Enum values**: Enums are simple symbolic constants with no associated data. Rust-style enums with payloads would unify with ADTs.
- **Nil safety**: `nil` and `void` are distinct observable outcomes. Future work should build ergonomic optional-flow helpers and type narrowing on top of that contract.
- **Structural typing**: All typing is nominal. Structural typing or interfaces/protocols would enable more flexible polymorphism.
