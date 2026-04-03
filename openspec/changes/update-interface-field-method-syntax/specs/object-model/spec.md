## ADDED Requirements

### Requirement: Fields Use Explicit Typed Declarations
Classes and interfaces SHALL declare required fields using the `field` member form, and field types SHALL be mandatory.

#### Scenario: Class field declaration requires a type
- **WHEN** a class declares `(field name String)`
- **THEN** the object model records a field named `name` with type `String`

#### Scenario: Untyped field declaration is rejected
- **WHEN** a class or interface declares `(field name)`
- **THEN** the compiler reports a field declaration error

### Requirement: Body-Less Methods Are Abstract Declarations
The object model SHALL treat a `method` member with no body expressions as an abstract method declaration.

#### Scenario: Abstract method declaration has no body
- **WHEN** a class or interface declares `(method size [x: Int] -> Int)`
- **THEN** the member is recorded as a method signature requirement and not as an executable method body

### Requirement: Concrete Methods Require A Body
The object model SHALL treat a `method` member with one or more body expressions as a concrete implementation, and concrete methods SHALL contain at least one expression.

#### Scenario: Concrete method includes a body
- **WHEN** a class declares `(method size [x: Int] -> Int (+ x 1))`
- **THEN** the member is recorded as an executable method implementation

#### Scenario: Empty implementation form is rejected
- **WHEN** a method is parsed as an implementation form but contains no body expressions
- **THEN** the compiler reports a method implementation error

### Requirement: Interfaces Declare Typed Members
Interfaces SHALL declare required fields and methods using the same `field` and `method` declaration shapes as classes.

#### Scenario: Interface declares typed field and method requirements
- **WHEN** an interface declares `(field name String)` and `(method render [ctx: Any] -> String)`
- **THEN** those members are recorded as interface requirements

#### Scenario: Interface methods are declaration-only in this change
- **WHEN** an interface method includes a body expression
- **THEN** the compiler reports an interface method error

### Requirement: Classes Declare Implemented Interfaces In The Header
Classes SHALL declare adopted interfaces in the class header using `implements`, not as a body member form.

#### Scenario: Class header declares one interface
- **WHEN** code declares `(class A implements InterfaceX ...)`
- **THEN** the class records `InterfaceX` as a required conformance target

#### Scenario: Class header declares multiple interfaces
- **WHEN** code declares `(class A implements [InterfaceX InterfaceY] ...)`
- **THEN** the class records both interfaces as required conformance targets

#### Scenario: Body-level `implement` form is rejected
- **WHEN** code places an `implement` member form inside a class body
- **THEN** the compiler reports a class member syntax error

### Requirement: Interface Conformance Requires Declared Members
A class implementing an interface SHALL provide all required fields and abstract method signatures declared by that interface.

#### Scenario: Implementing class satisfies field and method requirements
- **WHEN** an interface requires `(field name String)` and `(method render [ctx: Any] -> String)`
- **AND** a class declared with `implements InterfaceX` provides the same field and a compatible method implementation
- **THEN** the conformance check succeeds

#### Scenario: Missing required method is rejected
- **WHEN** a class declared with `implements InterfaceX` does not provide a required method
- **THEN** the compiler reports an interface conformance error

#### Scenario: Inherited parent method satisfies an interface requirement
- **WHEN** an interface requires `(method render [ctx: Any] -> String)`
- **AND** a class inherits a compatible `render` implementation from its parent class
- **THEN** the inherited method satisfies the interface requirement

#### Scenario: Inherited parent method with incompatible signature does not satisfy an interface
- **WHEN** an interface requires `(method render [ctx: Any] -> String)`
- **AND** a class inherits a `render` method from its parent class with an incompatible signature
- **THEN** interface conformance fails unless the class overrides that method with a compatible implementation

### Requirement: Interfaces Do Not Affect Runtime Dispatch Order
Interfaces SHALL constrain compile-time conformance only and SHALL NOT participate in runtime method lookup ahead of or alongside the class parent chain.

#### Scenario: Runtime dispatch uses class hierarchy, not interface declaration order
- **WHEN** a class implements an interface and also inherits a concrete parent implementation of the same method
- **THEN** runtime dispatch uses the inherited class implementation
- **AND** the interface only contributes signature validation during conformance checking
