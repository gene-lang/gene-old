## Context
Recent callable typing work clarified how function and method types should be stored and exposed, but member declaration syntax is still split across older and newer models. Today, typed fields are described through class metadata properties such as `^fields`, and the language does not cleanly separate method declarations from method implementations.

At the same time, interfaces need a source-level shape that:

- uses the same parameter syntax as classes
- supports field requirements and method requirements
- lets the checker reason about abstract members without inventing parallel declaration forms

## Goals / Non-Goals
- Goals:
  - Make field declarations explicit and typed.
  - Make abstract methods structurally distinct from concrete methods without adding a new keyword.
  - Keep declaration and implementation parameter syntax identical.
  - Define interface member syntax that mirrors class member syntax and class-header conformance syntax.
- Non-Goals:
  - Add default method bodies to interfaces in this change.
  - Add overloads or multiple abstract signatures under one method name.
  - Infer field types from assignments or constructor bodies.

## Decisions
- Decision: `field` replaces `prop`/`^fields` as the canonical field declaration form.
  - Canonical syntax is `(field name Type)`.
  - The type is mandatory.
  - `field` declares storage and typing requirements, not arbitrary metadata.

- Decision: abstract and concrete methods share one declaration form.
  - `(method m [x y: Int] -> Int)` is an abstract method declaration because it has no body.
  - `(method m [x y: Int] -> Int expr...)` is a concrete method implementation because it has at least one body expression.
  - A concrete implementation must contain at least one expression.

- Decision: method declarations always use named parameters.
  - Abstract methods and interface methods must use the same source-level parameter syntax as implementations.
  - Omitted parameter types default to `Any`.
  - Example: `(method m [x y: Int] -> Int)` means `x: Any`, `y: Int`.

- Decision: `Void`/`void` remain explicit.
  - `Void` is the return type.
  - `void` is the explicit value expression for implementations that do not return a meaningful result.
  - Implementations declared as `-> Void` should end with `void` rather than relying on an empty body or implicit fallback.

- Decision: interfaces use the same member declaration shapes as classes, but only abstract members.
  - Interfaces may declare fields with `(field name Type)`.
  - Interfaces may declare methods with `(method name [args...] -> Return)`.
  - Interface methods are declarations only in this change; they do not carry bodies.

- Decision: implemented interfaces are declared in the class header.
  - Canonical syntax is `(class A implements InterfaceX ...)` or `(class A implements [InterfaceX InterfaceY] ...)`.
  - The class body contains ordinary class members only; it does not contain a separate `implement` member form.
  - Interface conformance is checked after the full class body has been processed, so both direct and inherited members may satisfy the requirement set.

- Decision: conformance checks compare required fields and abstract method signatures structurally.
  - A class implementing an interface must provide every required field and method.
  - Method conformance uses the same public callable signature model already defined for methods.
  - Inherited methods from the class parent chain may satisfy interface requirements.
  - Interfaces do not participate in runtime method dispatch; they are compile-time contracts only.

## Trade-offs
- Requiring named parameters in declarations is more verbose than type-only signatures, but it keeps source declarations readable and aligned with implementations.
- Making `field` mandatory-typed is stricter than the current metadata style, but it produces clearer instance layout and better type checking.
- Using body presence to distinguish abstract from concrete methods is simple, but it means the parser and checker must reject ambiguous empty-body implementation cases explicitly.
- Moving `implements` into the class header makes class contracts obvious up front, but it requires the class parser to own conformance collection rather than treating interface adoption as an ordinary body member.
- Letting inherited class methods satisfy interfaces keeps reuse high and dispatch simple, but it means interface conformance must check inherited signatures, not just members declared directly on the class.

## Migration Plan
- Keep existing legacy field metadata forms only as compatibility syntax during transition if necessary, but print and document `field` as canonical.
- Migrate abstract/interface examples to named-parameter method declarations.
- Update class/interface tests to require explicit `void` for `Void`-returning implementations.

## Open Questions
- Whether interfaces should later permit default method bodies as a follow-up change rather than in the first pass.
  A: deferred
