# 7. Object-Oriented Programming

## 7.1 Classes

```gene
(class Point
  (ctor [x y]
    (/x = x)
    (/y = y))
  (method get_x [] /x)
  (method get_y [] /y)
  (method sum [] (/x + /y)))

(var p (new Point 3 4))
[(p .get_x) (p .get_y) (p .sum)]   # => [3 4 7]
```

- `/field` reads or writes instance fields
- Methods and constructors use array argument lists, just like functions. Use `[]` for zero arguments.
- Class constructors and methods are always eager. Macro-like OOP forms such as `ctor!`, `new!`, `method name!`, and `super .name!` are not supported; use a standalone `fn!` helper when quoted arguments are needed.

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
  (method get [] /value))

(var c (new Counter 0))
[(c .increment 5) c/.get]   # => [5 5]
```

### Method Calls
```gene
(class Counter
  (ctor [start] (/value = start))
  (method increment [n]
    (/value = (/value + n))
    /value)
  (method get [] /value))

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

(var p (new Person "Ada" 37))
[p/name p/age]   # => ["Ada" 37]
```

The `^fields` property declares field names and types as metadata.

## 7.5 Interfaces

Interfaces declare a visible surface of methods and fields.

```gene
(interface Readable
  (method read)
  (method close)
  (field name)
  (field closed ^readonly true))

((Readable .class) .name)   # => "Interface"
```

- `(method name)` declares a method on the interface.
- `(field name)` declares a field on the interface.
- `^readonly true` on a field prevents writes through adapter wrappers created from external implementations.

Interface declarations are currently name-based. Extra argument lists, return annotations, or field type tokens written inside an `interface` body are tolerated by the parser, but they are not used for runtime validation today.

## 7.6 Implementations And Adapters

### Inline Implementation

An inline `implement` inside a class declares that the class natively satisfies the interface.

```gene
(interface Readable
  (method read)
  (field name))

(class FileStream
  (implement Readable
    (method read []
      "file contents"))
  (ctor [name]
    (/name = name)))

(var fs (Readable (new FileStream "test.txt")))
fs/name     # => "test.txt"
```

Calling the interface on an inline implementation returns the original object, not an adapter wrapper.

### External Implementation

An external `implement` registers an adapter for an existing class.

```gene
(interface Readable
  (method read)
  (method close))

(class DataBuffer
  (ctor [data]
    (/data = data))
  (method get_data []
    /data)
  (method set_data [new_data]
    (/data = new_data)))

(implement Readable for DataBuffer
  (method read []
    (/_genevalue .get_data))
  (method close []
    (/_genevalue .set_data "")))

(var buffer (new DataBuffer "payload"))
(var readable (Readable buffer))
(readable .read)     # => "payload"
(readable .close)
(buffer .get_data)   # => ""
```

For external implementations:

- Calling the interface creates an adapter wrapper.
- If an interface field or method is declared but not explicitly implemented, the adapter falls back to a same-name member on the wrapped value.
- `_genevalue` refers to the wrapped value.
- `_geneinternal` exposes adapter-owned supplemental state.

### Adapter Constructors

External implementations can define `ctor` to initialize adapter-owned state.

```gene
(interface Ageable
  (method age))

(implement Ageable for Int
  (ctor [birth_year]
    (/_geneinternal/birth_year = birth_year))
  (method age []
    (/_genevalue - /_geneinternal/birth_year)))

((Ageable 2026 1990) .age)   # => 36
```

## 7.7 Inheritance

```gene
(class Shape
  (method area [] 0))

(class Circle < Shape
  (ctor [r] (/r = r))
  (method area [] (3.14159 * /r * /r)))

((new Circle 2) .area)   # => 12.56636
```

### Super Calls
```gene
(class BaseCounter
  (ctor [start]
    (/value = start))
  (method add [n]
    (/value = (/value + n))
    /value))

(class FastCounter < BaseCounter
  (ctor [start]
    (super .ctor start))      # Call parent constructor
  (method add [n]
    (super .add (n * 2))))    # Call parent method

(var c (new FastCounter 1))
(c .add 3)   # => 7
```

- `(super .method args...)` — call parent's regular method
- `(super .ctor args...)` — call parent constructor
- Single inheritance only (one parent class)

## 7.8 Field Access

```gene
(class Point
  (ctor [x y]
    (/x = x)
    (/y = y)))

(var p (new Point 3 4))
p/x             # => 3
(p/x = 10)
[p/x p/y]       # => [10 4]
```

## 7.9 `on_member_missing`

Dynamic member resolution for namespaces:

```gene
(ns Dynamic
  (.on_member_missing
    (fn [name]
      #"Dynamic/#{name}")))

Dynamic/foo   # => "Dynamic/foo"
```

---

## Potential Improvements

- **Interface member typing**: Interface declarations do not yet enforce argument types, return types, or field types at runtime.
- **Interface inheritance / composition**: Interfaces are flat declarations; there is no `extends`, mixin, or composition mechanism between interfaces.
- **External adapter mapping syntax**: Gene-level external implementations support computed methods and adapter constructors, but not explicit rename/hide declarations for methods or fields.
- **Inline readonly semantics**: `^readonly` on interface fields is enforced on adapter wrappers from external implementations, but inline implementations return the original object and do not add write guards.
- **Multiple inheritance / mixins**: Only single inheritance is supported. Mixins or trait composition would reduce duplication.
- **Access control**: All fields and methods are public. No `private`, `protected`, or module-private visibility.
- **Static methods**: No dedicated `static` method syntax. Must use namespace functions instead.
- **`on_member_missing` for instances**: Dynamic dispatch only works on namespaces, not class instances.
- **Field declaration**: Fields are implicitly created by assignment in constructors. An explicit declaration (`^fields`) exists but is metadata only — not enforced.
- **Class reopening**: Cannot add methods to an existing class after definition. Open classes (like Ruby) or extension methods would add flexibility.
- **Constructor overloading**: Only one constructor per class. No way to provide multiple construction patterns.
- **Macro-like OOP callables**: Intentionally unsupported. Keeping constructors and methods eager avoids extra inheritance and `super` dispatch complexity.
