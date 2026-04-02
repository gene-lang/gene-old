## Context
Gene's current function type support spans parser, type checker, descriptor interning, GIR serialization, and runtime validation. Across those layers, function signatures are still represented as a flat positional parameter list plus a positional rest index and keyword-splat booleans. That is sufficient for `(Fn [Int] String)`-style shapes, but it cannot faithfully encode canonical callable contracts that mix fixed keywords, keyword rest, positional variadics, and fixed positional suffix parameters.

The user-facing target shape is:

- `(Fn)`
- `(Fn [Int])`
- `(Fn [Int String] -> Int)`
- `(Fn -> Int)`
- `(Fn [Int ... String])`
- `(Fn [^a Int ^b String ^... Any Int ... String] -> String)`

## Goals / Non-Goals
- Goals:
  - Define one canonical `Fn` surface syntax that can express zero-arg, zero-return, positional variadic, fixed keyword, and keyword-rest contracts.
  - Preserve enough structure in stored type metadata to round-trip canonical function types exactly.
  - Unify functions and methods under one callable-signature model.
  - Require inference to collapse concrete callable definitions into those canonical shapes.
  - Keep effect annotations composable with the canonical `Fn` syntax.
- Non-Goals:
  - Introduce overloaded functions or multimethod dispatch.
  - Infer full effect sets from function bodies.
  - Make positional parameter names part of the function type contract.
  - Expose the implicit method receiver as a public first argument in method signatures.

## Decisions
- Decision: canonical function type syntax uses optional argument and return clauses.
  - `(Fn)` is shorthand for `(Fn -> Any)`.
  - `(Fn [Args])` is shorthand for `(Fn [Args] -> Any)`.
  - `(Fn -> Return)` means no parameters and a declared or inferred return type.
  - `(Fn [Args] -> Return)` means declared parameters and a declared or inferred return type.
  - Effect lists, when present, follow the optional return clause: `(Fn [Args] -> Return ! [Db])`.

- Decision: parameter items are stored by kind, not inferred from position.
  - Fixed positional parameter: `T`
  - Positional variadic segment: `T ...`
  - Fixed keyword parameter: `^name T`
  - Keyword rest parameter: `^... T`
  - This replaces the lossy combination of `params`, `rest_index`, `variadic`, and `kw_splat`.

- Decision: positional names are not part of the callable contract.
  - A function definition `[x: Int y: String] -> Int` infers to `(Fn [Int String] -> Int)`.
  - Keyword labels are part of the callable contract and are preserved.
  - Keyword-rest binding variable names are not part of the callable contract; a definition such as `[^opts...: Any]` infers to `^... Any`.

- Decision: methods use the same public callable shape as functions.
  - A method declaration `(method name [x: Int] -> String ...)` exposes the same caller-visible signature shape as a function: `(Fn [Int] -> String)`.
  - If the language wants a documentation alias such as `(Method [Int] -> String)`, it is an alias over the same callable model rather than a distinct argument-shape system.
  - The implicit receiver is not included in the public argument list because callers do not pass it explicitly.

- Decision: `Self` has a special contextual meaning.
  - `Self` is a reserved contextual type symbol, not a nominal class and not a runtime meta-type.
  - Inside class-scoped type contexts, `Self` resolves to the instance type of the enclosing class.
  - Outside class-scoped type contexts, `Self` is invalid.
  - Internal method metadata may store receiver information as `Self` even when the public method signature omits the receiver.

- Decision: `self` and `Self` are reserved identifiers.
  - `self` is the reserved receiver binding name for methods and other class-scoped receiver contexts.
  - No variable, parameter, field, function, class, or type alias may be declared with the name `self`.
  - `Self` is the reserved contextual receiver type symbol.
  - No class, type alias, generic parameter, or other type-level binding may be declared with the name `Self`.

- Decision: omitted return type defaults to `Any`.
  - `(Fn)` and `(Fn [Int])` normalize to `-> Any`.
  - `Any` means the callable places no return-value constraint on callers.
  - An explicit `-> Void` is distinct and means the callable must return the runtime `void` value.

- Decision: positional variadic placement must be preserved.
  - `(Fn [Int ... String])` means zero or more `Int` arguments followed by a final `String`.
  - A variadic segment is not implicitly forced to the tail of the parameter list.

- Decision: compatibility checks use canonical signature shape.
  - Required keyword labels must match exactly unless the target type includes `^... T`.
  - Positional variadic segments match the middle slice between fixed prefix and suffix parameters.
  - Missing annotations continue to degrade to `Any` where the gradual type system already permits that behavior.
  - A callable typed as `-> Void` is not interchangeable with `-> Any`; `Void` is an explicit return contract.
  - Method call compatibility uses the receiver-hidden signature at the call site and any stored receiver metadata for class/member validation.

## Proposed Representation
- `TypeExpr(TkFn)` and `TypeDesc(TdkFn)` should each carry:
  - `params: seq[CallableParam]`
  - `return_type`
  - `effects: seq[...]`
- `CallableParam` should carry:
  - `kind`: `CpPositional | CpPositionalRest | CpKeyword | CpKeywordRest`
  - `keyword_name` when applicable
  - `type`

This representation preserves canonical printing, compatibility checks, and GIR round-tripping without reconstructing meaning from side channels. Omitted return clauses are normalized to `Any`, so a separate `has_return_type` flag is not required.

## Function / Method Relationship
- Functions and methods share the same callable-signature structure.
- A method differs only by carrying receiver metadata in addition to its callable signature.
- Public method signatures omit the receiver and describe only caller-supplied arguments.
- Reflection can distinguish methods from free functions with a callable kind flag or alias without changing the argument contract.
- The reserved runtime receiver name is `self`, and the reserved type-level receiver symbol is `Self`.

## Trade-offs
- Richer function metadata adds some descriptor and serialization complexity, but it removes ambiguity that already leaks into the checker and runtime.
- Omitting positional names from types keeps types compact, but it means signature help and tooling must combine type metadata with source-level parameter names when both are needed.
- Treating keyword-rest as anonymous in the contract keeps equality and compatibility straightforward, but the runtime still needs to preserve the local binding name for execution.
- Normalizing omitted returns to `Any` keeps the contract compact, but it removes the ability to tell whether `Any` was written explicitly or arrived by defaulting.
- Hiding the receiver in method signatures keeps public types aligned with call syntax, but internal metadata still needs a receiver slot for dispatch and class-aware tooling.

## Migration Plan
- Accept the existing `(Fn [Args] Return)` form only as a compatibility parse path during migration, but print and serialize canonical arrow form.
- Convert existing function descriptor keys to the canonical signature structure before interning or GIR persistence.
- Update effect-system examples and checker parsing to consume the canonical arrow form.

## Open Questions
- Whether native metadata should expose keyword-rest value types directly or continue to rely on best-effort `Any` defaults until explicit registration is added.
