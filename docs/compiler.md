# Gene Compiler Architecture

**Date:** 2026-02-07  
**Status:** Implementation note — describes the current compiler pipeline and the
descriptor-first typing path in the Nim VM

## Overview

The compiler transforms Gene source code into executable bytecode:

```
Source Text → Parser → AST (Gene nodes) → Type Checker → Compiler → Bytecode (CompilationUnit) → VM
```

### Key Modules

| Module | File | Responsibility |
|--------|------|---------------|
| Parser | `parser.nim` | Text → AST (Gene/Value nodes) |
| Type Checker | `type_checker.nim` | Type inference and validation (compile-time) |
| Compiler | `compiler.nim` | AST → bytecode instructions |
| VM | `vm.nim` | Execute bytecode |
| GIR | `gir.nim` | Binary cache for CompilationUnits |

## Pipeline Stages

### 1. Parse

`parser.nim` reads source text and produces Gene nodes (S-expressions).

```gene
(fn add [x: Int y: Int] -> Int (x + y))
```

Becomes a Gene node where:
- Type is the symbol `fn`
- Children include the name `add`, param list `[x: Int y: Int]`, return annotation `-> Int`, and body `(x + y)`
- `: Int` is plain syntax — colons in param lists signal type annotations

The parser does NOT interpret types. It produces raw AST.

### 2. Type Check

`type_checker.nim` walks the AST and performs Hindley-Milner-style inference.

**What it does:**
- Builds a `TypeExpr` graph (TkAny, TkNamed, TkApplied, TkUnion, TkFn, TkVar)
- Resolves type variables through unification
- Attaches type metadata to AST nodes as properties (`__tc_param_types`, `__tc_return_type`, etc.)
- Reports type errors in strict mode; lenient in gradual mode (`strict=false`)

**What it produces:**
- Annotated AST nodes (type info attached as properties)
- Type descriptors (`TypeDesc` objects via `checker.type_descriptors()`)

**Current integration:**
```nim
# In parse_and_compile*:
let checker = if type_check: new_type_checker(strict = false) else: nil
# ... for each node:
checker.type_check_node(node)
# ... after all nodes:
self.output.type_descriptors = checker.type_descriptors()
```

The type checker runs as a pass over the AST before compilation. It's part of the compilation pipeline, not a separate tool.

### 3. Compile

`compiler.nim` transforms annotated AST into bytecode instructions stored in a `CompilationUnit`.

**Key data structures:**

```nim
CompilationUnit = ref object
  instructions: seq[Instruction]
  labels: Table[Label, int]
  type_descriptors: seq[TypeDesc]   # From type checker
  # ...

Instruction = object
  kind: InstructionKind
  arg0: Value      # First argument (can hold any Value)
  arg1: Value      # Second argument
```

**Scope tracking:**
The compiler uses `ScopeTracker` to map variable names to local indices. Variables are accessed by index at runtime, not by name.

### 4. Execute

`vm.nim` is a stack-based bytecode interpreter. It reads instructions from a CompilationUnit and executes them.

**Key runtime structures:**
- `Frame` — function call frame with local variable slots
- `Scope` — variable storage (array of Values indexed by ScopeTracker mappings)

## Type System Architecture

### Current State

The active pipeline is descriptor-first:

```
TypeChecker.TypeExpr
  → TypeDesc / TypeId
  → CompilationUnit.type_descriptors
  → ScopeTracker.type_expectation_ids / matcher.type_id / return_type_id
  → GIR serialization
  → runtime validation
```

Strings are still used for display and diagnostics, but not as the primary execution metadata path.

### Target Architecture

**One path. Real type objects. No strings.**

#### Built-in Type Registry

Built-in types exist before any compilation:

```nim
# Pre-created at compiler init, available to all compilations
BuiltinTypes = {
  "Int":     TypeDesc(kind: TdkNamed, name: "Int"),
  "Float":   TypeDesc(kind: TdkNamed, name: "Float"),
  "String":  TypeDesc(kind: TdkNamed, name: "String"),
  "Bool":    TypeDesc(kind: TdkNamed, name: "Bool"),
  "Nil":     TypeDesc(kind: TdkNamed, name: "Nil"),
  "Symbol":  TypeDesc(kind: TdkNamed, name: "Symbol"),
  "Char":    TypeDesc(kind: TdkNamed, name: "Char"),
  "Array":   TypeDesc(kind: TdkNamed, name: "Array"),
  "Map":     TypeDesc(kind: TdkNamed, name: "Map"),
  "Any":     TypeDesc(kind: TdkAny),
  # Applied types:
  # (Array Int) → TypeDesc(kind: TdkApplied, ctor: "Array", args: [IntTypeId])
  # (Result T E) → resolved when T, E are known
}
```

These are real objects, not strings. The compiler looks them up by name during compilation and resolves to a type descriptor immediately.

#### User Type Registration

When the compiler encounters a class or type definition:

```gene
(class Foo ...)
(type UserId (Int | String))
```

It creates a TypeDesc and registers it in the module's type registry. Subsequent references to `Foo` or `UserId` in that module resolve to the descriptor — at compile time.

#### Instruction-Level Type Storage

Type metadata is carried as `TypeId` references:

```
IkVar / IkVarValue / IkDefineProp
  → arg carries TypeId
  → runtime resolves through CompilationUnit.type_descriptors
  → validation runs against descriptor-derived runtime types
```

#### Type Resolution Flow

```
Source: (var x: Int 42)

1. Parser: produces AST with `: Int` annotation
2. Type Checker: resolves "Int" → TypeExpr(TkNamed, "Int")
3. Compiler: 
   - Looks up "Int" in type registry → gets TypeDesc
   - Emits IkVar instruction with TypeDesc attached
4. VM:
   - Reads instruction, sees TypeDesc
   - Validates value against TypeDesc directly
   - No string parsing, no runtime type name lookup
```

For user types:

```
Source: (class Foo ...) (var f: Foo (new Foo))

1. Compiler sees (class Foo ...):
   - Creates TypeDesc for Foo
   - Registers in module type registry
2. Compiler sees (var f: Foo ...):
   - Looks up "Foo" in type registry → finds TypeDesc
   - Emits instruction with TypeDesc
3. VM validates instance against TypeDesc
```

### What Still Matters

- `TypeExpr` remains the compile-time inference model.
- `TypeDesc` / `TypeId` are the runtime-facing metadata path.
- `runtime_types.nim` still converts descriptors to display strings for diagnostics.
- NaN-tag fast paths for built-in types still matter for runtime performance.

## Compiler Internals

### Instruction Set

Instructions are 16 bytes: `kind` (enum) + `arg0` (Value) + `arg1` (Value).

Key instruction categories:

| Category | Examples | Purpose |
|----------|---------|---------|
| Stack | IkPushValue, IkPop, IkDup | Stack manipulation |
| Variables | IkVar, IkVarAssign, IkVarResolve | Local variable ops |
| Arithmetic | IkAddValue, IkSubValue, IkMulValue | Math operations |
| Control | IkJump, IkJumpIfFalse, IkReturn | Control flow |
| Functions | IkFunction, IkUnifiedCall | Function def and calls |
| Classes | IkClass, IkMethod, IkNew | OOP |
| Collections | IkArrayStart, IkArrayEnd, IkMapStart | Array/Map construction |
| Types | IkMatchGeneType, IkTryUnwrap | Type checking, Result/Option |
| Modules | IkImport, IkExport | Module system |

### Scope Tracking

The compiler maps variable names to integer indices at compile time:

```nim
ScopeTracker = ref object
  parent: ScopeTracker
  next_index: int16
  mappings: Table[Key, int16]   # name → local slot index
```

At runtime, variables are accessed by index (fast array lookup), not by name.

### Function Compilation

Functions are compiled lazily by default:

1. Compiler sees `(fn add [x y] (x + y))`
2. Creates a `Function` object with the raw body
3. Emits `IkFunction` instruction that pushes the Function value
4. Body is compiled on first call (or eagerly with `eager_functions=true`)

### Matcher (Parameter Handling)

Function parameters are described by a `Matcher` tree:

```nim
Matcher = ref object
  kind: MatcherKind        # MkRoot, MkName, MkSplat, etc.
  name: Key                # Parameter name
  default_value: Value     # Default if not provided
  type_id: TypeId          # Type annotation descriptor id
  children: seq[Matcher]   # Sub-matchers for destructuring
```

The Matcher handles positional args, keyword args, defaults, splats, and destructuring. Type annotations on parameters flow through the Matcher.

## Generics

See `docs/proposals/implemented/generics-design.md` for the design note.

**Implemented now:** `fn first:A`, `method echo:T` — explicit type params attached to definition names.

**Compiler/runtime handling:** When the compiler/runtime sees `first:A`:
1. Split name on colons: `["first", "A"]`
2. Base name = `first`, type params = `["A"]`
3. Register `A` as a type variable descriptor (`TdkVar`) for the matcher path
4. Freshen generic type vars at each type-checker call site so the function stays polymorphic across calls

**Deferred:** generic classes, bounds/constraints, and runtime reified generic class instances.

## GIR (Gene Intermediate Representation)

GIR is a binary serialization of CompilationUnit for caching. When a `.gene` file is compiled, the result is cached as `.gir`. On subsequent runs, GIR is loaded instead of recompiling.

**Cache invalidation:** Source hash comparison — if the source changed, GIR is regenerated.

**Type descriptors in GIR:** serialized as part of the compilation unit, together with `type_aliases` and scope/matcher type ids.

**Current policy:** GIR is the cache format for the active descriptor-first pipeline. Cached modules preserve the same typing metadata as fresh compilation.

## Native Compilation

See `docs/proposals/implemented/native-codegen-design.md`.

The native pipeline extends the compiler output:

```
CompilationUnit → bytecode_to_hir → HIR (SSA form) → x86-64/ARM64 codegen → native function
```

Type information enables native optimization:
- Typed parameters → unboxed native types (int64, float64)
- Typed return values → skip NaN-boxing in hot loops
- Type-guided register allocation

Native compilation is optional — the VM always works as fallback.
