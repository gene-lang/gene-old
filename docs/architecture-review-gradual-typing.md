# Architecture Review: Gene for Gradual Typing / Static Language

**Reviewer:** Claude (AI)
**Date:** 2026-02-06
**Branch:** static-lang
**Scope:** src/gene/ — type system, compiler, VM, native codegen

## Verdict

**The foundation is solid for gradual typing, with clear gaps to close for full static typing.**

## What's Already Solid

### 1. Type Checker (1600 lines, fully functional)

`src/gene/type_checker.nim` implements a real Hindley-Milner-style unification engine:

- `TypeExpr` ADT: `TkAny`, `TkNamed`, `TkApplied`, `TkUnion`, `TkFn`, `TkVar`
- Proper occurs check, substitution resolution, scoped type environments
- Handles `var`, `fn`, `class`, `method`, `ctor`, `match`, `case`, `for`, `while`, `try/catch`
- ADT support with `Result<T,E>` and `Option<T>` built in
- Class inheritance tracking with field and method type lookups
- Integrated into compiler pipeline (`compiler.nim:4765`) with `strict = false` (gradual mode)

### 2. Runtime Type Validation

`src/gene/types/runtime_types.nim` provides the runtime half:

- NaN-tag-based fast type tests (`is_int`, `is_float`, `is_string`, etc.)
- `validate_type()` raises catchable Gene exceptions on mismatch
- Union, ADT, and function type compatibility at runtime
- Wired into VM: `IkVar`/`IkVarAssign` call `validate_type` when `type_expectations` exist (`vm.nim:1886-1978`)

### 3. NaN-Boxing Value Representation

The 8-byte NaN-boxed `Value` already encodes primitive type tags (INT, FLOAT, STRING, SYMBOL, ARRAY, MAP, INSTANCE, GENE):

- Primitive type checks are single bit-mask operations (no indirection)
- Tag space naturally segments typed vs untyped values
- Gradual typing gates on these tags at zero cost for primitives

### 4. Native Compilation Pipeline

`src/gene/native/hir.nim` defines a typed SSA-form IR (`HirType`: I64, F64, Bool, Ptr, Value) with x86-64 and ARM64 backends. Type information flows through to register allocation and instruction selection.

### 5. GIR Serialization

`src/gene/gir.nim` serializes `type_expectations` per scope into bytecode cache. Type information persists across compilation runs.

## Architectural Gaps

### 1. No Typed IR Between AST and Bytecode

Compiler goes AST → bytecode directly. No place for:
- Type-driven dead code elimination
- Monomorphization of generic functions
- Constant propagation with type knowledge
- Devirtualization of method calls

The HIR exists but only for the native JIT path.

### 2. Type Information is String-Based at Runtime

`type_expectations` stores type names as `string` in `ScopeTracker`. Runtime parses these strings on every type check (with cache). A numeric type-ID scheme would be faster.

### 3. Type Checker Doesn't Inform Bytecode Emission

The checker runs on AST *before* compilation but doesn't feed type info back into instruction selection. `(a + b)` emits the same instructions whether both are known `Int` or `Any`.

### 4. No Type Narrowing / Flow Typing

After `(if (x .is Int) ...)`, the type checker doesn't narrow `x` to `Int` in the then-branch. This is expected in modern gradual type systems (TypeScript, mypy, Kotlin).

### 5. No User-Defined Generics

`TkApplied` supports `Array<T>`, `Result<T,E>`, but users can't define generic functions or classes. ADT system parameters are hardcoded for `Result`/`Option`.

### 6. Class Fields Are Untyped at Runtime

Instance fields stored as raw `Value` arrays. `^fields` annotations exist only in the type checker's `ClassInfo`, not in runtime `Class` objects. No layout optimization for known-type fields.

## Gradual Typing Strengths

The architecture is better suited for gradual than full static typing:

1. **`Any` is the top type** — unannotated code defaults to `Any`, works dynamically
2. **Runtime checks at boundaries** — `validate_type` at var assignment and function calls
3. **Type checker is non-strict** — unknown types don't block compilation
4. **Dynamic dispatch with inline caches** — `IkUnifiedMethodCall*` handles "typed receiver, dynamic method" efficiently

## Recommendations

| Priority | Gap | Fix |
|----------|-----|-----|
| **P0** | String-based type expectations | Numeric `type_id` table (hybrid NaN-tag + object header) |
| **P0** | Type checker doesn't inform bytecode | Type-annotated instruction variants that skip dynamic dispatch |
| **P1** | No flow-based narrowing | `TkNarrow` in TypeExpr; narrow after type tests in if/match |
| **P1** | No user-defined generics | Extend `TkApplied`; monomorphize or type-erase |
| **P2** | No typed IR for bytecode path | Lightweight typed IR or type-annotated instructions |
| **P2** | Class field layout optimization | Pack `members` as typed slots when all field types known |

## Summary

The type checker is real (unification, ADTs, class hierarchy). Runtime validation works. NaN-boxing provides fast primitive type checks. The native JIT pipeline demonstrates typed execution. The main work is **integration** — making the type checker's knowledge flow into instruction selection and runtime optimizations — not fundamental redesign.

For full static (no dynamic fallback): needs typed IR, monomorphization, field layout optimization. For gradual typing with `Any` as escape hatch: this architecture can get there incrementally.
