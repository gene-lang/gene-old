# 1. Syntax & Literals

## 1.1 The Gene Data Structure

Gene is built around a universal data structure called the **Gene expression** — a tagged, property-carrying S-expression. Every Gene expression has three parts:

1. **Type** (head) — the first element, typically an operator, function name, or tag
2. **Properties** — named key-value pairs, prefixed with `^`
3. **Children** — positional elements

```gene
(type ^prop1 val1 ^prop2 val2 child1 child2 ...)
```

This structure serves as both **code** and **data** (homoiconicity):

```gene
# As code:
(fn add [a b] (a + b))

# As data:
(Person ^name "Alice" ^age 30 "child1" "child2")

# As template:
`(div (h1 %title) (p %content))
```

Gene is not merely S-expressions — the combination of type + properties + children makes it richer than traditional Lisp lists, enabling natural representation of structured data, DSLs, and configuration alongside code.

Whitespace (spaces, newlines, tabs) separates tokens. Indentation is not significant.

## 1.2 Comments

Line comments start with `#`:

```gene
# This is a comment
(var x 10)  # inline comment
```

Block comments use `#<` ... `>#`:

```gene
#<
  This is a block comment.
  It can span multiple lines.
>#
```

## 1.3 Primitive Literals

| Type      | Examples                  | Notes                          |
|-----------|---------------------------|--------------------------------|
| Integer   | `10`, `-3`, `0`           | 48-bit signed (NaN-boxed)      |
| Float     | `3.14`, `-0.5`, `1.0e10` | IEEE 754 double                |
| String    | `"hello"`, `""`           | UTF-8, heap-allocated, supports newlines |
| Boolean   | `true`, `false`           | Keywords, not symbols          |
| Nil       | `nil`                     | Absence of value               |
| Character | `'A'`, `'z'`             | Single Unicode character       |
| Symbol    | `` `hello ``              | Interned, used as identifiers  |

## 1.4 String Interpolation

Strings prefixed with `#` support interpolation:

```gene
(var name "Gene")
(var greeting #"Hello, #{name}!")   # => "Hello, Gene!"
```

Expressions inside `#{}` are evaluated at runtime.

## 1.5 Quoting

Backtick preserves structure as data (unevaluated):

```gene
(var expr `(+ 1 2))        # A Gene value, not evaluated
(println expr/.type)       # => +
(println expr/.children)   # => [1 2]
```

Within quoted expressions, `%` marks an unquote. Use `$render` to substitute values:

```gene
(var x 5)
(var tmpl `(+ 1 %x))
(println ($render tmpl))    # => (+ 1 5)
```

## 1.6 Accessing Gene Values

Quoted Gene expressions can be inspected at runtime via built-in accessors:

```gene
(var g `(Person ^name "Alice" ^age 30 "child1" "child2"))
g/.type       # => Person (the first element)
g/.props      # => {name: "Alice", age: 30}
g/.children   # => ["child1", "child2"]
```

Properties and children can be mixed freely in the expression — the parser separates `^`-prefixed pairs from positional values.

## 1.7 Keywords (Reserved)

These identifiers cannot be redefined:

**Control**: `if`, `ifel`, `elif`, `else`, `then`, `fn`, `class`, `var`, `loop`, `break`, `continue`, `return`, `for`, `in`, `while`, `do`, `repeat`

**Exception**: `try`, `catch`, `finally`, `throw`

**Module**: `import`, `from`, `ns`

**OOP**: `new`, `method`, `ctor`, `super`

**Special**: `nil`, `void`, `true`, `false`, `macro`, `async`, `await`, `yield`, `enum`, `type`

## 1.8 Identifiers

Identifiers may contain letters, digits, underscores, and certain punctuation:

- Names ending with `!` denote macro functions (unevaluated args)
- Names ending with `*` denote generator functions
- Names ending with `?` denote predicate functions (convention)
- Names starting with `$` denote globals: `$env`, `$ex`, `$program`, `$args`
- Names starting with `/` denote properties or exports

## 1.9 Path Expressions (Slash Syntax)

The `/` operator accesses members:

```gene
arr/0           # Array index
map/key         # Map key
obj/property    # Instance property
ns/member       # Namespace member
arr/0/name      # Chained access
```

Special forms:
- `obj/.method` — no-arg method call shorthand
- `map/key/!` — assert non-nil (throws if missing)

## 1.10 Range Syntax

Ranges use the infix `..` form inside a Gene expression. The two-endpoint form is inclusive. Stepped ranges use the `range` constructor.

```gene
(var closed (0 .. 3))
(println closed)
(var stepped (range 1 5 2))
(println stepped)
# => 0..3
# => 1..5 step 2
```

`(start .. end)` is shorthand for `(range start end)` with an implicit step of `1`. A `start..end:step` literal is not currently implemented; use `(range start end step)` instead.

---

## Integer Range and Overflow

Integers are signed 64-bit values (range: −9,223,372,036,854,775,808 to 9,223,372,036,854,775,807). Small integers within ±2^47 are stored as NaN-boxed immediates (no heap allocation); larger values auto-promote to heap-allocated references transparently.

Arithmetic overflow (exceeding the int64 range) raises an exception:

```gene
(+ 9223372036854775807 1)   # => Exception: Integer overflow in addition
(- -9223372036854775808 1)  # => Exception: Integer overflow in subtraction
(* 9223372036854775807 2)   # => Exception: Integer overflow in multiplication
```

## Potential Improvements

- **Raw strings**: No raw string literal (no escape processing). Useful for regex patterns and file paths.
- **Bigint support**: No arbitrary-precision integers. Overflow throws instead of promoting to bigint. Consider adding a bigint type for programs that need unbounded integer arithmetic.
