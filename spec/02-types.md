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
| `Instance`  | Class instance with properties        |
| `Function`  | First-class function/closure          |
| `Class`     | Class definition                      |
| `Namespace` | Namespace scope                       |
| `Future`    | Async computation result              |
| `Generator` | Lazy value producer                   |
| `Thread`    | Concurrent execution                  |
| `Regex`     | Compiled regular expression           |
| `Range`     | Numeric range (lazy)                  |
| `Enum`      | Enumeration type                      |

## 2.2 Type Annotations

Annotations are optional (gradual typing). When present, they are checked at compile time.

```gene
# Variable
(var x: Int 10)

# Function parameters and return type
(fn add [a: Int b: Int] -> Int
  (a + b))

# Class fields
(class Point
  ^fields {^x Int ^y Int}
  (ctor [x: Int y: Int]
    (/x = x)
    (/y = y)))
```

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
- **Type bounds/constraints**: No way to express `T: Comparable` or similar constraints on generic type parameters.
- **Inference completeness**: Type inference does not propagate through all expressions — some positions require explicit annotations.
- **Union type narrowing**: Flow-sensitive narrowing works in `if` branches but not in all contexts (e.g., `case/when` arms).
- **Enum values**: Enums are simple symbolic constants with no associated data. Rust-style enums with payloads would unify with ADTs.
- **Nil safety**: No distinction between "explicitly nil" and "undefined/void". `void` exists internally but is not a first-class user concept, which can lead to confusion when accessing missing keys.
- **Structural typing**: All typing is nominal. Structural typing or interfaces/protocols would enable more flexible polymorphism.
- **Type aliases in method signatures**: Type aliases are not consistently respected in all positions.
