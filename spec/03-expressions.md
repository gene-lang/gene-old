# 3. Expressions & Operators

## 3.1 Everything is an Expression

Every construct in Gene returns a value. There are no statements.

```gene
(var x (if (3 > 2) then "left" else "right"))
(println x)
(var y (do
  (var n 1)
  (n += 2)
  n))
(println y)
# => left
# => 3
```

## 3.2 Arithmetic Operators

Infix within parentheses:

```gene
(println (10 + 3))
(println (10 - 3))
(println (10 * 3))
(println (10 / 3))
(println (10 % 3))
(println (2 + 3 * 4))
# => 13
# => 7
# => 30
# => 3.3333333333333335
# => 1
# => 14
```

## 3.3 Augmented Assignment

```gene
(var x 10)
(x += 5)
(println x)
(x -= 2)
(println x)
(x *= 3)
(println x)
(x /= 2)
(println x)
(x %= 5)
(println x)
# => 15
# => 13
# => 39
# => 19.5
# => 4.5
```

## 3.4 Comparison Operators

```gene
(println (3 == 3))
(println (3 != 4))
(println (5 > 2))
(println (5 < 2))
(println (5 >= 5))
(println (4 <= 3))
# => true
# => true
# => true
# => false
# => true
# => false
```

## 3.5 Logical Operators

```gene
(println (true && true))
(println (true || false))
(println (true &|& false))
(println (! false))
(println (false || true && false))
# => true
# => true
# => true
# => true
# => false
```

Precedence (high to low): `*/%` → `+-` → comparisons → `&&` → `&|&` → `||`

## 3.6 Assignment

```gene
(var x 10)
(println x)
(x = 20)
(println x)
# => 10
# => 20
```

## 3.7 `do` Blocks

Sequence expressions, returning the last:

```gene
(var result (do
  (var a 5)
  (var b 8)
  (a + b)))
(println result)
# => 13
```

## 3.8 `ifel` (Inline Conditional)

Fixed-arity conditional expression:

```gene
(println (ifel (7 > 10) "big" "small"))
# => small
```

---

## Potential Improvements

- **Operator overloading**: Operators like `+`, `==` are not overloadable for user types. Allowing method-based dispatch for operators would enable cleaner DSLs and custom numeric types.
- **Chained comparisons**: `(1 < x < 10)` is not supported. Must write `((x > 1) && (x < 10))`.
- **Bitwise operators**: No bitwise AND, OR, XOR, shift operators. Needed for low-level work, protocol implementations, and flag manipulation.
- **Precedence transparency**: Operator precedence within S-expressions can be surprising since Lisp traditionally has no precedence (explicit nesting). The implicit precedence in `(2 + 3 * 4)` may confuse users coming from either Lisp or C backgrounds.
- **String concatenation operator**: Strings use `.append` method or interpolation. A `++` or `~` operator for string concatenation would be convenient.
- **Compound expressions**: No `let` binding form for introducing multiple bindings in a single expression (must use `do` + multiple `var`).
