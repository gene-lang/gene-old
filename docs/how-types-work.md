# How Types Work in Gene Today

This document explains the current typing pipeline:

`Source -> Parse -> Type Check (gradual) -> Compile -> GIR -> Execute`

It uses `examples/sample_typed.gene` as the running example.

## Quick run commands

```bash
./bin/gene run examples/sample_typed.gene
./bin/gene parse examples/sample_typed.gene
./bin/gene compile --format pretty examples/sample_typed.gene
./bin/gene run --trace-instruction examples/sample_typed.gene
```

## 1. Parse phase

Parser entry points are in `src/gene/parser.nim`.

The parser builds `Value` trees (`VkGene`, `VkArray`, `VkSymbol`, ...). It does not perform type validation. Type annotations stay as normal syntax nodes (for example `x:` followed by `Int`).

## 2. Type check phase (gradual mode)

Type checker lives in `src/gene/type_checker.nim`.

Compilation creates it as non-strict:

- `new_type_checker(strict = false, ...)`

in `src/gene/compiler/pipeline.nim`.

Implications:

- It still infers and unifies types (`TypeExpr`: `TkAny`, `TkNamed`, `TkApplied`, `TkUnion`, `TkFn`, `TkVar`).
- In most mismatch cases it emits warnings instead of compile-time hard errors.
- Unknown type names are allowed during compile-time in gradual mode.

Warnings are flushed per top-level node in the compiler pipeline and printed with source location when available.

## 3. Descriptor-first compile pipeline

The refactor uses descriptor IDs directly instead of old string metadata props.

Core runtime metadata types are in `src/gene/types/type_defs.nim`:

- `TypeId` (`int32`)
- `TypeDesc` (`TdkAny`, `TdkNamed`, `TdkApplied`, `TdkUnion`, `TdkFn`, `TdkVar`)

Built-in type IDs come from `src/gene/types/descriptors.nim` (`Any=0`, `Int=1`, ...).

### Where type IDs are attached

1. Function and method signatures

- `to_function` parses annotations and sets `matcher.children[i].type_id`.
- Return annotation sets `matcher.return_type_id`.
- Matcher carries the descriptor table via `matcher.type_descriptors`.
- Explicit generic params on functions/methods use definition-name syntax like `identity:T`.
- Generic type params are interned as `TdkVar` descriptors for the matcher path.

2. Typed local variables

- Compiler resolves `(var x: T ...)` to a `TypeId`.
- It stores expected type IDs in `ScopeTracker.type_expectation_ids`.
- It also emits `IkVar`/`IkVarValue` with type metadata.

3. Typed class properties

- `(prop x: T)` compiles to `IkDefineProp` with the resolved `TypeId`.
- Class stores `prop_types` and descriptor table for runtime checks.

4. Type aliases

- `(type Alias Expr)` is resolved to a `TypeId` and stored in `CompilationUnit.type_aliases`.
- The same form now also binds a runtime type value, so `Alias` can be used in value position:

```gene
(type X (String | Nil))
X
(types_equivalent X `(Nil | String))
```

- Standalone type expressions also compile to runtime type values:

```gene
(String | Nil)
(Fn [Int] String)
```

## 4. Runtime enforcement

Runtime checks are in `src/gene/vm/args.nim` and `src/gene/vm/exec.nim`, implemented by helpers in `src/gene/types/runtime_types.nim`.

### Function arguments

- `process_args_core` validates annotated params via `validate_or_coerce_type`.
- This can coerce some numeric cases (for example `Int -> Float`, `Float -> Int` with warning).

### Return values

- Explicit `return` and implicit end-of-function returns are validated for annotated functions/methods.

### Variables

- `IkVar`, `IkVarValue`, `IkVarAssign`, `IkVarAssignInherited` enforce expected slot types via `validate_type`.

### Typed instance properties

- `IkSetMember` checks `class.prop_types` and validates/coerces before assignment.

### Nil behavior

- Most runtime checks skip validation when the value is `NIL`.
- So `nil` is effectively allowed through many typed boundaries in gradual mode.

### Generic/applied type behavior

- Applied checks like `(Array Int)` are currently shallow at runtime: outer constructor is checked, element-level enforcement is limited.
- Generic function type params are compile-time only today: runtime validation treats `TdkVar` as `Any`, while the checker preserves the param/return relationship statically.

## 5. GIR serialization

GIR serializer is `src/gene/gir.nim`.

Current version is:

- `GIR_VERSION = 18`

Typing-relevant data persisted in GIR:

- `module_types` tree (`ModuleTypeNode`)
- `type_descriptors` table (`seq[TypeDesc]`)
- `type_aliases`
- Scope tracker snapshots include `type_expectation_ids`

## 6. Module boundary typing

During type checking, `import` can load imported GIR and use `module_types` metadata to register imported type names. This improves gradual checking across modules even without loading full source.

## 7. What `--no-type-check` does now

`--no-type-check` disables both:

- compile-time checker pass (no warnings/errors from `TypeChecker`)
- runtime typed validation paths (because VM runs with `type_check = false`)

So typed annotations remain in syntax but are not enforced when this flag is set.

## 8. Practical notes

- `gene run` may use cached GIR. Use `--no-gir-cache` or `--force-compile` when validating typing changes from source.
- If behavior looks inconsistent between source and cache, confirm whether the GIR was built before recent typing changes.

## Summary

The current system is descriptor-based and gradual-first:

1. Compile-time inference and warnings (`strict=false`).
2. Runtime boundary enforcement using `TypeId` + `TypeDesc`.
3. GIR persistence for descriptor and module type metadata.

This is the active implementation model for mixed typed/untyped Gene code.
