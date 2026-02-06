# Architecture Review: Gene as a Gradual-First Language

**Reviewer:** Claude (AI)
**Date:** 2026-02-06
**Branch:** static-lang2
**Scope:** src/gene/ — type system, compiler, VM, native codegen

## Verdict

**The foundation is strong for a gradual-first language. The priority should be optional type safety on top of dynamic semantics, not convergence to a strict static language.**

## Product Direction (Gradual-First)

1. **Dynamic remains baseline**: unannotated code must keep working with `Any` and dynamic dispatch.
2. **Types are opt-in guarantees**: annotations improve safety, tooling, and optimization where desired.
3. **Strictness is optional**: strict modes should be per module/profile, not global language policy.
4. **Optimizations are semantics-preserving**: typed fast paths must always have dynamic fallback.
5. **Static-only features are secondary**: prioritize features that improve mixed typed/untyped code first.

## Design Decisions to Preserve

1. **Two-layer type model**: compile-time uses symbolic `TypeExpr` analysis; runtime uses value/class objects and NaN-tag checks. They are intentionally connected by metadata, not a single shared object graph.
2. **Predeclaration for forward references**: compiler predeclares local/module names so definitions can be referenced before textual declaration where supported.
3. **Runtime type preservation is selective**: locals and function params carry enforceable expectations today; namespace/class-member storage is still mostly dynamic unless explicitly checked.

## What's Already Solid

### 1. Type Checker (~2k lines, fully functional)

`src/gene/type_checker.nim` implements a real Hindley-Milner-style unification engine:

- `TypeExpr` ADT: `TkAny`, `TkNamed`, `TkApplied`, `TkUnion`, `TkFn`, `TkVar`
- Proper occurs check, substitution resolution, scoped type environments
- Handles `var`, `fn`, `class`, `method`, `ctor`, `match`, `case`, `for`, `while`, `try/catch`
- ADT support with `Result<T,E>` / `Option<T>` built in, plus user-defined parametric ADTs via `type`
- Class inheritance tracking with field and method type lookups
- Integrated into compiler pipeline via `parse_and_compile*` with `strict = false` (gradual mode)

### 2. Runtime Type Validation

`src/gene/types/runtime_types.nim` provides the runtime half:

- NaN-tag-based fast type tests (`is_int`, `is_float`, `is_string`, etc.)
- `validate_type()` raises catchable Gene exceptions on mismatch
- Union, ADT, and function type compatibility at runtime
- Wired into VM variable and argument binding paths (`IkVar`, `IkVarAssign`, `IkVarAssignInherited`, and matcher-based arg processing) when type expectations exist

### 3. NaN-Boxing Value Representation

The 8-byte NaN-boxed `Value` already encodes primitive type tags (INT, FLOAT, STRING, SYMBOL, ARRAY, MAP, INSTANCE, GENE):

- Primitive type checks are single bit-mask operations (no indirection)
- Tag space naturally segments typed vs untyped values
- Gradual typing gates on these tags at zero cost for primitives

### 4. Native Compilation Pipeline

`src/gene/native/hir.nim` defines a typed SSA-form IR (`HirType`: I64, F64, Bool, Ptr, Value) with x86-64 and ARM64 backends. Type information flows through to register allocation and instruction selection.

### 5. GIR Serialization

`src/gene/gir.nim` serializes `type_expectations` per scope into bytecode cache. Type information persists across compilation runs.

### 6. Module Type Metadata Across Imports

Module definitions now carry structural type metadata (`ModuleTypeNode`) through compilation and GIR serialization, and the type checker consumes this during import resolution. This directly improves gradual typing at module boundaries.

## Architectural Gaps (Against Gradual-First Goals)

### 1. No Typed IR Between AST and Bytecode (Optimization Gap)

Compiler goes AST → bytecode directly. No place for:
- Type-driven dead code elimination
- Monomorphization of generic functions
- Constant propagation with type knowledge
- Devirtualization of method calls

The HIR exists but only for the native JIT path.

### 2. Type Information is String-Based at Runtime

`type_expectations` stores type names as `string` in `ScopeTracker`. Runtime parsing is cached by type string, so repeated checks are mostly cache lookups. Also, common primitive checks are already fast via NaN tags. The remaining issue is string-heavy handling for annotated/non-primitive paths, where numeric type IDs would be cleaner and faster.

### 3. Type Checker Only Partially Informs Bytecode Emission

The checker feeds metadata into compilation (binding/param/return type props), and the compiler/VM already use that for gradual boundary validation. What is missing is optional opcode specialization/typed instruction selection for performance; this is a secondary optimization track, not a correctness blocker for gradual typing.

### 4. No Type Narrowing / Flow Typing

After `(if (x .is Int) ...)`, the type checker doesn't narrow `x` to `Int` in the then-branch. This is expected in modern gradual type systems (TypeScript, mypy, Kotlin).

### 5. No First-Class Generics for Functions/Classes

`TkApplied` supports applied types (`Array<T>`, `Map<K,V>`, etc.), and users can define parametric ADTs. The missing piece is first-class generics for functions/classes (with proper polymorphic instantiation/monomorphization). Constructor typing is still partially special-cased (`Ok`/`Err`/`Some`/`None`).

### 6. Class Fields Are Untyped at Runtime

Instance fields stored as raw `Value` arrays. `^fields` annotations exist only in the type checker's `ClassInfo`, not in runtime `Class` objects. No layout optimization for known-type fields.

## Deferred / Out of Scope (Current Phase)

- **Interfaces and type aliases**: currently compile-time oriented in the compiler path; runtime enforcement remains limited.
- **Comptime-heavy type features**: kept separate from runtime gradual guarantees.
- **Enum/interface deep integration**: tracked as follow-up work; not required to deliver core gradual-first goals.

## Gradual Typing Strengths

The architecture is better suited for gradual than full static typing:

1. **`Any` is the top type** — unannotated code defaults to `Any`, works dynamically
2. **Runtime checks at boundaries** — `validate_type` at var assignment and function calls
3. **Type checker is non-strict** — unknown types don't block compilation
4. **Dynamic dispatch with inline caches** — `IkUnifiedMethodCall*` handles "typed receiver, dynamic method" efficiently

## Recommendations

| Priority | Gap | Fix |
|----------|-----|-----|
| **P0** | No flow-based narrowing | Add control-flow narrowing in `if`/`case`/`match` after type tests |
| **P0** | Gradual boundary UX | Improve runtime type error diagnostics (location, expected/actual, binding context) |
| **P0** | Metadata continuity | Ensure type metadata survives compile/cache/import boundaries consistently |
| **P1** | String-heavy runtime expectations | Add numeric `type_id` table while preserving string compatibility |
| **P1** | Type metadata not used for specialization | Add optional specialized instruction variants with dynamic fallback |
| **P2** | No first-class generics for fn/class | Add polymorphic fn/class generics; choose monomorphization or erasure |
| **P2** | No typed IR for bytecode path | Introduce lightweight typed IR only if needed for measurable wins |
| **P2** | No runtime field layout optimization | Pack fields as typed slots only behind optional optimization mode |

## Summary

The type checker is real (unification, ADTs, class hierarchy). Runtime validation works. NaN-boxing provides fast primitive type checks. The native JIT pipeline demonstrates typed execution. The main work is **gradual-first integration**: better flow typing and boundary ergonomics first, then optional specialization where it pays off.

Full static mode can remain a future optional track. The near-term strategy should optimize the mixed typed/untyped experience so Gene can support diverse application styles without forcing strictness.
