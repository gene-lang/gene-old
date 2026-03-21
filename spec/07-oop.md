# 7. Object-Oriented Programming

## 7.1 Classes

```gene
(class Point
  (ctor [x y]
    (/x = x)
    (/y = y))
  (method get_x _ /x)
  (method get_y _ /y)
  (method sum _ (/x + /y)))
```

- `/property` reads or writes instance properties
- `_` in method signature means no parameters (besides implicit self)

## 7.2 Constructors

### Regular Constructor
```gene
(class Rect
  (ctor [w h]
    (/w = w)
    (/h = h)))

(var r (new Rect 3 4))
```

## 7.3 Methods

### Regular Methods
```gene
(class Counter
  (ctor [start] (/value = start))
  (method increment [n]
    (/value = (/value + n))
    /value)
  (method get _ /value))
```

### Method Calls
```gene
(var c (new Counter 0))
(c .increment 5)    # Parenthesized: with arguments
c/.get              # Slash-dot: no arguments (shorthand)
```

### Callable Instances

If a class defines a `call` method, instances can be invoked like functions:

```gene
(class Multiplier
  (ctor [factor] (/factor = factor))
  (method call [x] (x * /factor)))

(var times3 (new Multiplier 3))
(times3 7)    # => 21
```

## 7.4 Class Fields Metadata

```gene
(class Person
  ^fields {^name String ^age Int}
  (ctor [name age]
    (/name = name)
    (/age = age)))
```

The `^fields` property declares field names and types as metadata.

## 7.5 Inheritance

```gene
(class Shape
  (method area _ 0))

(class Circle < Shape
  (ctor [r] (/r = r))
  (method area _ (3.14159 * /r * /r)))
```

### Super Calls
```gene
(class FastCounter < BaseCounter
  (ctor [start]
    (super .ctor start))      # Call parent constructor
  (method add [n]
    (super .add (n * 2))))    # Call parent method
```

- `(super .method args...)` — call parent's regular method
- `(super .ctor args...)` — call parent constructor
- Single inheritance only (one parent class)

## 7.6 Property Access

```gene
# Inside methods/constructor: use /
/x              # Read property
(/x = value)    # Write property

# Outside: use instance/property
(var p (new Point 3 4))
p/x             # => 3
(p/x = 10)     # Write
```

## 7.7 `on_member_missing`

Dynamic member resolution for namespaces:

```gene
(ns Dynamic
  (.on_member_missing
    (fn [name]
      #"Dynamic/#{name}")))

Dynamic/foo    # => "Dynamic/foo"
```

---

## Potential Improvements

- **Interfaces / protocols**: No way to declare that multiple classes implement the same contract. Must rely on duck typing.
- **Multiple inheritance / mixins**: Only single inheritance is supported. Mixins or trait composition would reduce duplication.
- **Access control**: All properties and methods are public. No `private`, `protected`, or module-private visibility.
- **Static methods**: No dedicated `static` method syntax. Must use namespace functions instead.
- **`on_member_missing` for instances**: Dynamic dispatch only works on namespaces, not class instances.
- **Property declaration**: Properties are implicitly created by assignment in constructors. An explicit declaration (`^fields`) exists but is metadata only — not enforced.
- **Method `_` syntax**: Using `_` for no-arg methods is non-obvious. Consider `(method get [] /value)` for consistency with functions.
- **Abstract methods**: No way to declare a method that subclasses must implement. The base class `(method area _ 0)` gives a default instead of forcing override.
- **Class reopening**: Cannot add methods to an existing class after definition. Open classes (like Ruby) or extension methods would add flexibility.
- **Constructor overloading**: Only one constructor per class. No way to provide multiple construction patterns.
- **`new` vs `new!` split**: Having two instantiation forms adds cognitive overhead. Consider unifying by inspecting the constructor type.
