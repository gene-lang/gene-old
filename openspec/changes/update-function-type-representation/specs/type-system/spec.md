## MODIFIED Requirements

### Requirement: Type Expression Syntax
The language SHALL accept type expressions as standard Gene forms, including primitives, generic constructors, unions, and canonical function types.

Canonical function types SHALL support all of the following surface forms:
- `(Fn)`
- `(Fn [Args])`
- `(Fn -> Return)`
- `(Fn [Args] -> Return)`

Within `Args`, each parameter item SHALL be one of:
- `T` for a fixed positional parameter
- `T ...` for a positional variadic segment
- `^name T` for a fixed keyword parameter
- `^... T` for keyword-rest parameters

An effect list, when present, SHALL follow the optional return clause as `! [Effect ...]`.

When the return clause is omitted, the function type SHALL default to `Any`. Therefore:
- `(Fn)` is equivalent to `(Fn -> Any)`
- `(Fn [Args])` is equivalent to `(Fn [Args] -> Any)`

#### Scenario: Canonical function types parse
- **WHEN** a function is annotated with `(Result (Array User) ApiError)`, `(A | B | C)`, `(Fn)`, `(Fn [Int])`, `(Fn [Int ... String])`, or `(Fn [^a Int ^b String ^... Any Int ... String] -> String)`
- **THEN** the compiler records the corresponding type expression in the AST

#### Scenario: Omitted return defaults to `Any`
- **WHEN** the compiler parses `(Fn)` or `(Fn [Int])`
- **THEN** the resulting function type uses `Any` as its return type

#### Scenario: Explicit `Void` return remains distinct
- **WHEN** the compiler parses `(Fn -> Void)`
- **THEN** the resulting function type requires a `Void` return
- **AND** it is not treated as equivalent to `(Fn -> Any)`

### Requirement: Keyword Parameter Types
The language SHALL preserve keyword parameter labels and keyword-rest value types in function signatures, and the compiler SHALL validate keyword arguments against those entries.

#### Scenario: Declared keyword arguments are validated by label
- **WHEN** a function type uses `(Fn [^limit Int ^offset Int String] -> String)` and a call supplies `^limit 10 ^offset 0 "users"`
- **THEN** the keyword arguments are accepted
- **AND** their values are type-checked against the declared keyword parameter types

#### Scenario: Keyword rest accepts undeclared keywords with a shared value type
- **WHEN** a function type uses `(Fn [^limit Int ^... String] -> String)` and a call supplies `^limit 10 ^sort "name" ^dir "asc"`
- **THEN** the undeclared keyword arguments are accepted
- **AND** each extra keyword value is type-checked as `String`

#### Scenario: Undeclared keywords are rejected without keyword rest
- **WHEN** a function type uses `(Fn [^limit Int] -> String)` and a call supplies `^limit 10 ^sort "name"`
- **THEN** the compiler reports an argument error and rejects the call in type-check mode

## ADDED Requirements

### Requirement: Canonical Function Signature Storage
The type system SHALL store function types as canonical callable signatures that preserve parameter kind, keyword labels, variadic position, keyword-rest value type, and explicit return type constraints.

#### Scenario: Structured storage round-trips a mixed signature
- **WHEN** the compiler interns the function type `(Fn [^a Int ^b String ^... Any Int ... String] -> String)`
- **THEN** the stored descriptor preserves two fixed keyword parameters, one keyword-rest parameter, one positional variadic segment, one fixed positional suffix parameter, and an explicit `String` return type
- **AND** converting that descriptor back to source form yields `(Fn [^a Int ^b String ^... Any Int ... String] -> String)`

#### Scenario: Omitted return is stored as `Any`
- **WHEN** the compiler interns `(Fn)` or `(Fn [Int])`
- **THEN** the stored descriptor uses `Any` as the return type
- **AND** the function remains compatible with the shorthand source forms

#### Scenario: Explicit `Void` return is preserved
- **WHEN** the compiler interns `(Fn -> Void)`
- **THEN** the stored descriptor preserves `Void` as the return type
- **AND** printing the descriptor yields `(Fn -> Void)`

### Requirement: Functions And Methods Share One Callable Model
The type system SHALL use one callable-signature model for functions and methods. Method surface signatures SHALL describe only caller-supplied arguments, while receiver typing SHALL be stored separately.

#### Scenario: Method signature omits implicit receiver
- **WHEN** a method is declared as `(method render [width: Int] -> String ...)`
- **THEN** its public callable signature is `(Fn [Int] -> String)`
- **AND** the implicit receiver is not exposed as a first argument in that signature

#### Scenario: Method alias may reuse the same signature shape
- **WHEN** tooling or documentation chooses to render the same method contract as `(Method [Int] -> String)`
- **THEN** it refers to the same caller-visible callable signature as `(Fn [Int] -> String)`
- **AND** it does not introduce an extra `Self` argument into the public signature

### Requirement: `Self` Is A Contextual Type Symbol
The type system SHALL treat `Self` as a special contextual type symbol for the enclosing class instance type.

#### Scenario: `Self` resolves inside class scope
- **WHEN** a class member annotation references `Self`
- **THEN** the compiler resolves it to the instance type of the enclosing class

#### Scenario: `Self` is rejected outside class scope
- **WHEN** a top-level function or variable annotation references `Self`
- **THEN** the compiler reports an invalid contextual type error

### Requirement: `self` And `Self` Are Reserved
The language SHALL reserve `self` for receiver bindings and `Self` for the contextual receiver type. User code SHALL NOT declare either name for another purpose.

#### Scenario: Variable binding named `self` is rejected
- **WHEN** user code declares a variable, parameter, or function named `self`
- **THEN** the compiler reports a reserved identifier error

#### Scenario: Type-level binding named `Self` is rejected
- **WHEN** user code declares a class, type alias, generic parameter, or other type-level binding named `Self`
- **THEN** the compiler reports a reserved identifier error

### Requirement: Function Type Inference
The compiler and type checker SHALL infer canonical function types from callable definitions based on parameter declarations, keyword labels, rest bindings, keyword splats, and return annotations or inferred return types.

#### Scenario: Zero-arg function with no declared return infers `(Fn -> Any)`
- **WHEN** a function has no parameters and no declared or inferred return type contract
- **THEN** its inferred type is `(Fn -> Any)`

#### Scenario: Positional parameters with inferred return use canonical arrow form
- **WHEN** a function has two positional parameters of types `Int` and `String` and an inferred return type of `Int`
- **THEN** its inferred type is `(Fn [Int String] -> Int)`

#### Scenario: Variadic positional middle segment is preserved
- **WHEN** a function definition has a positional variadic parameter over `Int` values followed by a fixed trailing `String` parameter
- **THEN** its inferred type is `(Fn [Int ... String])`

#### Scenario: Keyword and keyword-rest parameters infer canonical contract form
- **WHEN** a function definition has keyword parameters `^a: Int` and `^b: String`, a keyword splat accepting `Any`, a positional variadic segment of `Int`, a trailing positional `String`, and a `String` return type
- **THEN** its inferred type is `(Fn [^a Int ^b String ^... Any Int ... String] -> String)`

#### Scenario: Method inference hides receiver from the public signature
- **WHEN** a method definition has one user-declared `Int` parameter and a `String` return type
- **THEN** its inferred public callable signature is `(Fn [Int] -> String)`
- **AND** the receiver type is tracked separately as `Self`
