## Why
Method and constructor argument syntax currently diverges from function definitions by accepting `_` as a special no-argument form. That inconsistency adds parser/compiler surface area and keeps examples in the OOP docs out of line with the rest of the language.

## What Changes
- Remove `_` as a valid argument form for `method` and `ctor` definitions.
- Require array argument lists for methods and constructors, including external `implement` bodies.
- Update implementation-facing specs, examples, and tests to use `[]` for zero-argument methods/constructors.
- Emit clear compile-time errors when legacy `_` syntax is used.

## Impact
- Affected specs: oop
- Affected code: `src/gene/compiler/functions.nim`, `src/gene/compiler/interfaces.nim`, `spec/07-oop.md`, `testsuite/07-oop/`, adapter/interface tests
- **BREAKING**: Existing code using `(method name _ ...)` or `(ctor _ ...)` will stop compiling and must be rewritten to `(method name [] ...)` and `(ctor [] ...)`.
