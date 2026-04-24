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

Chained comparisons are supported — `(a < b <= c)` is equivalent to `((a < b) && (b <= c))`:

```gene
(println (1 < 2 <= 3))
(println (1 <= 2 <= 3 <= 4))
(println (5 > 3 > 1))
# => true
# => true
# => true
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

## Gene Expression Evaluation

A Gene expression has a type/callee position, zero or more properties, and zero
or more children. In ordinary calls, the type/callee is resolved to a function,
method, macro-like function, class, or special form according to the owning
syntax.

ordinary calls evaluate property values and child expressions before calling the
resolved function or method. Property values in ordinary calls become keyword
arguments, while children become positional arguments.

Quoted Gene values are data. They retain their `.type`, `.props`, and
`.children` so macros, templates, and DSL code can inspect or transform them.
Compiler-recognized metadata is form-specific; do not assume arbitrary
properties create stable runtime metadata unless the owning spec says so.

---

## Potential Improvements

- None
