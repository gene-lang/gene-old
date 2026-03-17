# Object Model

## ADDED Requirements

### Requirement: Classes are first-class Gene values
The runtime SHALL represent every class as a Gene value whose type is `Class`. A class value SHALL expose Gene-visible metadata including `^name`, `^parent`, `^ctor`, `^methods`, and optional `^on_method_missing`.

#### Scenario: Static class definition has a canonical class value
- **WHEN** a program defines a class
- **THEN** the resulting class SHALL behave as a Gene value equivalent to the same metadata expressed directly.

```gene
(class Point < Object
  (ctor [x y]
    (/x = x)
    (/y = y)
  )
  (method distance _
    (sqrt ((/x * /x) + (/y * /y)))
  )
)

# Canonical shape
(Class
  ^name Point
  ^parent Object
  ^ctor (fn [x y]
    (/x = x)
    (/y = y)
  )
  ^methods {
    ^distance (fn _
      (sqrt ((/x * /x) + (/y * /y)))
    )
  }
)
```

#### Scenario: Dynamically constructed Class values are instantiable
- **WHEN** a program constructs a class value at runtime
- **THEN** `new` SHALL instantiate it and method dispatch SHALL use the provided metadata.

```gene
(var DynamicGreeter
  (Class
    ^name `DynamicGreeter
    ^parent Object
    ^methods {
      ^greet (fn [] "hello from dynamic class")
    }
  )
)

(var obj (new DynamicGreeter))
(obj .greet)
```

### Requirement: Instances are canonical Gene values
An instance SHALL be a Gene value whose type slot is the class being instantiated. Instance props and optional children SHALL remain observable as Gene data.

#### Scenario: Instantiation produces a value typed by its class
- **WHEN** a program evaluates `(new Point 3 4)`
- **THEN** the resulting value SHALL behave as an instance of `Point`
- **AND** the instance state SHALL be observable as Gene props.

```gene
(class Point
  (ctor [x y]
    (/x = x)
    (/y = y)
  )
)

(var point (new Point 3 4))

# Canonical instance shape
(Point ^x 3 ^y 4)
```

### Requirement: The object hierarchy includes built-ins and bootstrap classes
The language SHALL expose a single inheritance hierarchy rooted at `Object`. `Class` SHALL inherit from `Object`, `Class` SHALL be an instance of itself as a bootstrap special case, and built-in classes such as `Int`, `String`, `Bool`, `Array`, `Map`, and `Nil` SHALL inherit from `Object`.

#### Scenario: User-defined instances satisfy direct and ancestor checks
- **GIVEN** a class `Point < Object` and `(var point (new Point 3 4))`
- **WHEN** code evaluates `is`
- **THEN** direct and ancestor checks SHALL both succeed.

```gene
(point is Point)
(point is Object)
```

#### Scenario: Bootstrap classes satisfy Class semantics
- **WHEN** code evaluates bootstrap relationships
- **THEN** the bootstrap invariants SHALL hold.

```gene
(Class is Class)
(Class is Object)
(Object is Class)
(Object is Object)
```

#### Scenario: Built-in values are Objects
- **WHEN** code evaluates `is` against built-in values
- **THEN** those values SHALL participate in the same hierarchy.

```gene
(42 is Int)
(42 is Object)
("hi" is String)
(nil is Nil)
(nil is Object)
```

### Requirement: Method resolution follows the parent chain
Method lookup SHALL search the receiver class's `^methods`, then walk the `^parent` chain, then walk the same chain for `^on_method_missing`, and SHALL throw only if no method or fallback is found. Constructors SHALL inherit through the same `^parent` chain when a subclass does not override `^ctor`.

#### Scenario: A subclass inherits a parent constructor
- **WHEN** a subclass omits its own constructor
- **THEN** instantiation SHALL use the first constructor found in its parent chain.

```gene
(class Animal
  (ctor [name]
    (/name = name)
  )
)

(class Dog < Animal
  (method speak [] "Woof!")
)

(var d (new Dog "Rex"))
d/name
```

#### Scenario: A subclass inherits on_method_missing
- **WHEN** a parent class defines `on_method_missing`
- **AND** a subclass does not override it
- **THEN** missing methods on subclass instances SHALL use the inherited fallback.

```gene
(class Proxy
  (on_method_missing [name args...]
    (println "intercepted:" name)
    nil
  )
)

(class LoggingProxy < Proxy)

(var lp (new LoggingProxy))
(lp .anything)
```

### Requirement: Nil is a null object with nil-safe receiver navigation
`nil` SHALL be the sole instance of `Nil < Object`. When the current receiver is `nil`, property navigation and zero-argument method navigation SHALL yield `nil`. The strict selector `/!` SHALL throw when the current navigation value is `nil` or `void`.

#### Scenario: Nil method navigation returns nil
- **WHEN** code navigates methods from `nil`
- **THEN** the result SHALL remain `nil`.

```gene
nil/.anything
nil/.foo/.bar/.baz
```

#### Scenario: Nil property navigation returns nil
- **GIVEN** `(var obj nil)`
- **WHEN** code navigates properties from that receiver
- **THEN** the chain SHALL collapse to `nil`.

```gene
obj/x
obj/x/y/z
```

#### Scenario: Strict navigation rejects nil or missing values
- **WHEN** code asserts with `/!` before continuing traversal
- **THEN** evaluation SHALL throw if the current value is `nil` or `void`.

```gene
x/!/.foo
obj/x/!/y
```
