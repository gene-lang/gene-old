## Why
Gene's current class/member surface mixes older `prop`/`^fields` conventions with newer typed callable work, and it still lacks a clear spec for abstract methods and interface members. That leaves three important areas underspecified:

- whether field declarations are storage declarations or ad hoc metadata
- how to distinguish abstract method declarations from concrete method implementations
- how interfaces should declare typed fields and methods in a way that matches class syntax

The proposed surface should make these declarations uniform and explicit:

- `(field name Type)`
- `(method m [x y: Int] -> Int)` for an abstract signature
- `(method m [x y: Int] -> Int expr...)` for a concrete implementation

## What Changes
- Replace class field declarations based on `prop`/`^fields` with explicit `field` declarations where the type is mandatory.
- Define body-less `method` forms as abstract method declarations and require concrete method implementations to contain at least one body expression.
- Specify that declaration and implementation parameter syntax always uses named parameters; omitted parameter types default to `Any`.
- Add interface syntax and semantics for typed field requirements and abstract method requirements using the same declaration rules as classes, with implemented interfaces declared in the class header via `implements`.
- Require `void` to be written explicitly in implementations that return no meaningful value, with `Void` as the return type.

## Impact
- Affected specs: `object-model`, `type-system`
- Affected code:
  - class/member parsing and lowering
  - interface compilation and validation
  - typed field/method checking
  - class/interface tests and docs
