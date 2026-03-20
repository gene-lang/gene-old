# 3. Expressions & Operators

## 3.1 Everything is an Expression

Every construct in Gene returns a value. There are no statements.

```gene
(var x (if (a > b) then a else b))   # if returns a value
(var y (do (step1) (step2) result))   # do returns last expression
```

## 3.2 Arithmetic Operators

Infix within parentheses:

```gene
(x + y)       # Addition
(x - y)       # Subtraction
(x * y)       # Multiplication
(x / y)       # Division
(x % y)       # Modulo
(2 + 3 * 4)   # Precedence respected: => 14
```

## 3.3 Augmented Assignment

```gene
(x += 5)      # x = x + 5
(x -= 2)      # x = x - 2
(x *= 3)      # x = x * 3
(x /= 2)      # x = x / 2
```

## 3.4 Comparison Operators

```gene
(x == y)      # Equal
(x != y)      # Not equal (also: x <> y)
(x > y)       # Greater than
(x < y)       # Less than
(x >= y)      # Greater or equal
(x <= y)      # Less or equal
```

## 3.5 Logical Operators

```gene
(x && y)      # Logical AND (short-circuit)
(x || y)      # Logical OR (short-circuit)
(! x)         # Logical NOT
```

## 3.6 Assignment

```gene
(var x 10)    # Declaration + binding
(x = 20)      # Reassignment
```

## 3.7 `do` Blocks

Sequence expressions, returning the last:

```gene
(var result (do
  (var a 5)
  (var b 8)
  (a + b)))     # => 13
```

## 3.8 `ifel` (Inline Conditional)

Fixed-arity conditional expression:

```gene
(ifel (x > 10) "big" "small")
```

---

## Potential Improvements

- **Operator overloading**: Operators like `+`, `==` are not overloadable for user types. Allowing method-based dispatch for operators would enable cleaner DSLs and custom numeric types.
- **Chained comparisons**: `(1 < x < 10)` is not supported. Must write `((x > 1) && (x < 10))`.
- **Bitwise operators**: No bitwise AND, OR, XOR, shift operators. Needed for low-level work, protocol implementations, and flag manipulation.
- **Ternary sugar**: `ifel` works but the name is non-obvious. Consider whether `(if cond then a else b)` is sufficient or if a shorter form is needed.
- **Precedence transparency**: Operator precedence within S-expressions can be surprising since Lisp traditionally has no precedence (explicit nesting). The implicit precedence in `(2 + 3 * 4)` may confuse users coming from either Lisp or C backgrounds.
- **String concatenation operator**: Strings use `.append` method or interpolation. A `++` or `~` operator for string concatenation would be convenient.
- **Compound expressions**: No `let` binding form for introducing multiple bindings in a single expression (must use `do` + multiple `var`).
