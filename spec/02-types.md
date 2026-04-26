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
| `Enum`      | Enumeration and enum ADT definitions, members, and values |

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
```

Enum ADTs use `enum` declarations, not a separate ADT declaration syntax:

```gene
(enum Result:T:E
  (Ok value: T)
  (Err error: E)
  Empty)

(fn accept_result [r: (Result Int String)] -> String
  "accepted")
```

The declaration head `Result:T:E` declares generic parameters. The canonical enum name is `Result`, and concrete type positions use `(Result Int String)`.

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

Enum type annotations accept values whose parent enum matches the annotated enum name, including generic enum applications:

```gene
(enum Status ready done)
(fn accept_status [s: Status] -> String "ok")

(enum Result:T:E
  (Ok value: T)
  (Err error: E)
  Empty)
(fn accept_result [r: (Result Int String)] -> String "ok")
```

Enum payload field annotations are part of the construction and type-checking contract. Constructors validate concrete annotated fields when values are built, and annotated boundaries use the parent enum name plus generic arguments to check enum values.

## 2.5 Enum ADTs

`enum` is the only public ADT declaration model. The same declaration form covers simple symbolic enumerations, unit variants, and payload variants:

```gene
(enum Shape
  (Circle radius: Float)
  (Rect width: Int height: Int)
  Point)

(var circle (Shape/Circle 5.0))
(var rect (Shape/Rect ^height 20 ^width 10))
(var point Shape/Point)

(assert ((circle .radius) == 5.0))
(assert ((rect .width) == 10))
(assert ((typeof circle) == "Shape"))
```

A unit variant has no payload fields and can be used directly (`Shape/Point`) or called with no arguments (`(Shape/Point)`). A payload variant declares fields in order; those names define positional construction order, keyword construction names, field access names, and pattern binding order. Positional and keyword construction are both supported, but a single constructor call cannot mix the two forms.

```gene
(var by_position (Shape/Rect 10 20))
(var by_keyword (Shape/Rect ^height 20 ^width 10))
(assert (by_position == by_keyword))
```

Field annotations are checked when constructing payload variants. A concrete mismatch raises a type error; an omitted field annotation remains gradual and accepts any value.

```gene
(enum Metric
  (Counter value: Int))

(var counter (Metric/Counter 7))
(try
  (Metric/Counter "bad")
catch *
  (println "typed payload rejected"))
```

Generic enum heads use `Name:T:U` syntax. The canonical enum name is the base name before the first `:`, and concrete type positions apply the generic arguments with ordinary type-expression syntax.

```gene
(enum Result:T:E
  (Ok value: T)
  (Err error: E)
  Empty)

(fn accept_result [r: (Result Int String)] -> String
  "accepted")
```

Enum value equality is nominal by enum variant and structural by payload: two values are equal when they come from the same enum variant and their payload values are equal. Unit variants from the same enum member compare equal. `typeof` returns the parent enum name, not the individual variant name. Display strings such as `Shape/Point` and `(Shape/Circle 5.0)` are for presentation; they are not the canonical identity. Enum identity is nominal and is preserved through imports, GIR cache artifacts, runtime serialization, and tree serialization.

`Result` and `Option` are enum-backed built-ins. `Ok`, `Err`, `Some`, and `None` are ordinary enum variant constructors/values for the built-in `Result` and `Option` identities, and their qualified forms are `Result/Ok`, `Result/Err`, `Option/Some`, and `Option/None`. The `?` operator unwraps `Ok` and `Some`, returns early with built-in `Err` and `None`, and treats same-named variants from user-defined enums as ordinary values.

Legacy Gene-expression ADT declarations such as `(type (Result T E) ...)` are migration errors, not an alternate supported model. New code should use `enum Result:T:E ...` and `enum Option:T ...`; legacy quoted Result/Option-shaped Gene values do not satisfy enum ADT type boundaries.

The declaration contract includes diagnostics for malformed enum declarations, duplicate variants, duplicate fields, invalid generic parameters, invalid field annotations, constructor arity errors, missing or unknown keyword arguments, mixed positional/keyword calls, and typed payload mismatches.

## 2.6 Enumerations

Simple symbolic enumerations are the unit-variant subset of enum ADTs:

```gene
(enum Color red green blue)
Color/red     # Access member
```

The `^values` spelling is accepted as simple-enum sugar and canonicalizes to ordered unit variants:

```gene
(enum Status ^values [ready done])
Status/ready
```

---

## Potential Improvements

- **Generic classes**: Only generic functions and generic enum declarations are supported. Generic classes (`class Stack:T`) are not yet implemented.
- **Duration/Period arithmetic**: Date/time literals and comparisons are implemented, but arithmetic (adding durations, computing date differences) is not yet supported.
- **Bytes operations**: Byte literals and basic accessors (`.size`, `.get`, `.to_array`) are implemented. Bitwise operations, `.slice`, `.concat`, and bytes-to-string conversion are not yet available.
- **Type bounds/constraints**: No way to express `T: Comparable` or similar constraints on generic type parameters.
- **Inference completeness**: Type inference still falls back to `Any` in some complex binding positions, notably destructuring parameters and other non-trivial patterns.
- **Union type narrowing**: Flow-sensitive narrowing works in `if` branches and some ADT-aware control-flow positions, but not in every control-flow form or arbitrary predicate.
- **Enum ADT refinements**: The core enum ADT contract is implemented through `enum`; future refinements may add enum-specific methods, optimizer specialization, richer constructor ergonomics, and additional pattern forms such as guards, or-patterns, and as-patterns.
- **Nil safety**: `nil` and `void` are distinct observable outcomes. Future work should build ergonomic optional-flow helpers and type narrowing on top of that contract.
- **Structural typing**: All typing is nominal. Structural typing or interfaces/protocols would enable more flexible polymorphism.
