## ADDED Requirements

### Requirement: Method Declarations Use Named Parameters
Abstract methods, interface methods, and concrete method implementations SHALL use named parameter declarations. Parameter names are required even when a parameter type defaults to `Any`.

#### Scenario: Abstract method with omitted parameter type defaults to `Any`
- **WHEN** code declares `(method m [x y: Int] -> Int)`
- **THEN** the type system records the signature as if `x: Any` and `y: Int`

#### Scenario: Type-only abstract method declaration is rejected
- **WHEN** code declares `(method m [Int] -> Int)`
- **THEN** the compiler reports a method declaration error because method declarations require parameter names

### Requirement: Abstract Method Signatures Produce Callable Types
Abstract method declarations SHALL participate in type checking using the same public callable signature model as concrete methods.

#### Scenario: Abstract method declaration yields a callable signature
- **WHEN** code declares `(method render [ctx: Any] -> String)`
- **THEN** the type system records a public callable signature equivalent to `(Fn [Any] -> String)`

### Requirement: `Void` Implementations Use Explicit `void`
Concrete methods and functions declared with return type `Void` SHALL use the explicit `void` value when they do not return a meaningful result.

#### Scenario: `Void` implementation ends with `void`
- **WHEN** code declares `(method close [resource: Any] -> Void void)`
- **THEN** the implementation type-checks against `Void`

#### Scenario: Body-less `Void` declaration remains abstract
- **WHEN** code declares `(method close [resource: Any] -> Void)`
- **THEN** the member is treated as an abstract declaration and not as a concrete implementation
