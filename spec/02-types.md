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
| `Thread`    | Concurrent execution                  |
| `Regex`     | Compiled regular expression           |
| `Range`     | Numeric range (lazy)                  |
| `Date`      | Calendar date                         |
| `DateTime`  | Date + time snapshot                  |
| `Bytes`     | Byte sequence                         |
| `Enum`      | Enumeration type                      |

### Range

Ranges are lazy numeric sequences. `(start .. end)` creates an inclusive range with step `1`; `(range start end step)` creates a stepped range.

```gene
(println (typeof (0 .. 3)))
(println (range 1 5 2))
# => VkRange
# => 1..5 step 2
```

### Date and DateTime

`Date` and `DateTime` are runtime-backed value types exposed through `gene/today`, `gene/yesterday`, `gene/tomorrow`, and `gene/now`.

The parser also reserves `YYYY-MM-DD` and `YYYY-MM-DDTHH:MM:SS` for Date/DateTime literals, but direct literal evaluation is not yet wired through end-to-end. Use the stdlib constructors above in current user code.

```gene
(println (typeof (gene/today)))
(println (typeof (gene/now)))
(println (((gene/now) .to_i) > 0))
# => VkDate
# => VkDateTime
# => true
```

### Bytes

`Bytes` values exist in the runtime as `VkBytes`, but the standalone literal forms are not yet user-facing. The parser-reserved binary/hex/base64 prefixes (`0!`, `0*`, `0#`) are still incomplete, so current programs usually obtain bytes through string helpers.

```gene
(println (typeof ("ABC" .bytes)))
(println ("ABC" .each_byte))
# => VkBytes
# => [65 66 67]
```

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
- **Date/DateTime literals**: The parser recognizes date and datetime token shapes, but direct literal evaluation is still incomplete. Construction currently goes through stdlib helpers such as `gene/today` and `gene/now`.
- **Bytes ergonomics**: `VkBytes` exists, but direct literals, indexing, and richer byte-oriented methods are not fully surfaced to Gene code yet.
- **Type bounds/constraints**: No way to express `T: Comparable` or similar constraints on generic type parameters.
- **Inference completeness**: Type inference still falls back to `Any` in some complex binding positions, notably destructuring parameters and other non-trivial patterns.
- **Union type narrowing**: Flow-sensitive narrowing works in `if` branches and ADT-aware `case/when` arms, but not in every control-flow form or arbitrary predicate.
- **Enum values**: Enums are simple symbolic constants with no associated data. Rust-style enums with payloads would unify with ADTs.
- **Nil safety**: No distinction between "explicitly nil" and "undefined/void". `void` exists internally but is not a first-class user concept, which can lead to confusion when accessing missing keys.
- **Structural typing**: All typing is nominal. Structural typing or interfaces/protocols would enable more flexible polymorphism.
