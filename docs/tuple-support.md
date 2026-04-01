# Tuple Support

## Overview

Tuples are lightweight, immutable, fixed-size data structures. They serve as pure data containers -- behavior is provided through standalone functions, not methods.

**Key distinction from classes:** Classes bundle data + behavior. Tuples are just structured data.

**Key distinction from frozen arrays (`#[...]`):** Frozen arrays are untyped, homogeneous-feeling collections. Named tuples carry a type tag, enforce per-field types at construction, support named field access. Anonymous tuples are closer to frozen arrays but still support type enforcement and destructuring.

## Syntax

### Defining a tuple type

```gene
(tuple Point x: Int y: Int)
(tuple X first: String Int Int)    # mixed named/positional fields
(tuple Pair Int Int)               # all positional
```

Fields can be named (`x: Int`) or positional (`Int`). Named fields are accessed by name or index; positional fields by index only.

### Field ordering

Fields are ordered by declaration order, left to right. Index 0 is always the first declared field, regardless of whether it is named or positional. In `(tuple X first: String Int Int)`:

| Index | Name    | Type   |
|-------|---------|--------|
| 0     | `first` | String |
| 1     | (none)  | Int    |
| 2     | (none)  | Int    |

### Creating instances

```gene
# Named tuple type
(var p (new Point 3 4))

# Anonymous tuple
(var pair (new tuple "hello" 42))
```

Constructor arguments are positional, matching declaration order.

### Accessing fields

```gene
# By name (named fields only)
p/x    => 3
p/y    => 4

# By index (all fields)
p/0    => 3
p/1    => 4

# Anonymous tuples - index only
pair/0 => "hello"
pair/1 => 42
```

## Properties

### Immutability

Tuples are immutable after construction. To create a modified copy, use the `.clone` builtin:

```gene
(var p1 (new Point 3 4))
(var p2 (p1 .clone ^x 10))
p2/x => 10
p2/y => 4

# Positional update by index:
(var t (new tuple 1 2 3))
(var t2 (t .clone ^0 10))
t2/0 => 10
```

`.clone` is a standalone method. It returns a new tuple; the original is unchanged.

### Type enforcement

Field types are enforced at construction time (and by `.clone`). Passing a value that doesn't match the declared type is a runtime error.

```gene
(tuple Pair String Int)
(new Pair "hello" 42)     # ok
(new Pair 42 "hello")     # runtime error: expected String, got Int
```

### Nominal typing

Tuple types are nominal -- the type name is the identity. Two tuple types with the same fields but different names are distinct types.

```gene
(tuple Point x: Int y: Int)
(tuple Vec2 x: Int y: Int)

(== (new Point 3 4) (new Point 3 4))   => true   # same type, same values
(== (new Point 3 4) (new Vec2 3 4))    => false   # different types
(== (new Point 3 4) (new Point 3 5))   => false   # same type, different values
```

Anonymous tuples compare structurally by field count and values (they have no type name).

### Destructuring

```gene
(var [x y] p)           # positional destructure
x => 3
y => 4

(var [first _ third] t)  # skip fields with _
```

### Pattern matching

Uses `case`/`when` (Gene's pattern matching construct):

```gene
(case point
  when (Point 0 0)      "origin"
  when (Point x 0)      #"on x-axis at #{x}"
  when (Point 0 y)      #"on y-axis at #{y}"
  when (Point x y)      #"at #{x}, #{y}"
)
```

## Behavior model

Tuples are pure data. Use standalone functions to operate on them:

```gene
(fn distance [a b]
  (math/sqrt ((((a/x - b/x) ** 2)) + ((a/y - b/y) ** 2)))
)

(var p1 (new Point 0 0))
(var p2 (new Point 3 4))
(distance p1 p2)  => 5.0
```

## Examples

```gene
# RGB color as a tuple
(tuple Color r: Int g: Int b: Int)
(var red (new Color 255 0 0))

(fn color_to_hex [c]
  #"##(hex c/r)#(hex c/g)#(hex c/b)"
)

# Return multiple values from a function
(fn divmod [a b]
  (new tuple (a / b) (a % b))
)
(var [quotient remainder] (divmod 10 3))

# Lightweight records
(tuple HttpResponse status: Int body: String)
(var resp (new HttpResponse 200 "OK"))
resp/status => 200
```
