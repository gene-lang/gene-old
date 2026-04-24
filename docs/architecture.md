# Gene VM Architecture

This document describes the VM-based implementation that lives under `src/gene/`.
The execution pipeline looks like this:

```
source.gene ──► Parser ──► AST ──► Compiler ──► CompilationUnit ──► VM ──► result
                           │                         │
                           └──────► GIR writer ◄─────┘
```

## Components

### Command Front-End (`src/gene.nim`, `src/commands/`)
- All CLI behaviour is routed through a `CommandManager`.
- `run`, `eval`, `repl`, `parse`, `compile`, `pipe`, and `lsp` commands live in `src/commands/*.nim`.
- `run` optionally loads cached Gene IR (`*.gir`) from `build/`, otherwise parses and compiles on the fly.
- Shared helpers set up logging, initialise the VM (`init_app_and_vm`), and register runtime namespaces.

### Parser (`src/gene/parser.nim`)
- Reads S-expressions, supports macro dispatch (quote/unquote, `@decorators`, string interpolation).
- Produces nested `Gene` nodes backed by `Value` (not plain Nim objects), retaining metadata for later phases.
- Macro readers are stored in two dispatch tables (`macros` and `dispatch_macros`) making it easy to extend syntax.

### Compiler (`src/gene/compiler.nim`)
- Walks the parsed form and emits instructions defined in `InstructionKind`.
- Handles special forms (conditionals, loops, namespaces, class definitions, `$caller_eval`).
- Builds argument matchers so functions, macros, and methods can destructure their inputs.
- Produces a `CompilationUnit` (instruction stream + constant table + metadata) consumed by the VM or the GIR serializer.

### Gene IR (GIR) (`src/gene/gir.nim`)
- Serialises/deserialises `CompilationUnit` objects.
- Embeds version info, compiler fingerprint, and optional source hash for cache validation.
- `gene compile` writes GIR files; `gene run` can execute them directly.

### Virtual Machine (`src/gene/vm.nim`)
- Stack-based VM with computed-goto dispatch (`{.computedGoto.}` pragma).
- Each `Frame` owns a 256-slot value stack, an instruction pointer, argument list, and scope chain.
- Scope objects form a linked list; ref-counted manually to avoid churn (see `IkScopeStart`/`IkScopeEnd`).
- Macro-aware call path keeps arguments unevaluated when `Function.is_macro_like` is set.
- Async I/O with event loop integration; VM polls asyncdispatch every 100 instructions.
- Includes tracing (`VM.trace`), profiling (`VM.profiling`, `instruction_profiling`), and GIR-aware execution.

### VM Correctness Checks

- `checked VM mode` is a debug/test harness, not the default execution mode.
- The check hooks are compiled only when the binary is built with `-d:geneVmChecks`.
- `VirtualMachine.checked_vm` defaults to `false`; `run`, `eval`, and `pipe` enable it only through `--checked-vm`.
- In normal builds, `--checked-vm` fails early with guidance to rebuild using `-d:geneVmChecks`.
- Checked mode validates structural runtime-state invariants around dispatch: program counter range, compilation-unit presence, instruction trace shape, stack underflow/overflow projections, local/scope bounds, exception handler shape, and selected refcount boundary checks.
- Failures are reported as `VM invariant failed` diagnostics with the current PC, opcode kind, boundary label, and detail. The checks are intentionally practical boundary assertions, not full retain/release accounting or formal proof of every exception-flow transition.

## Value Representation (`src/gene/types/`)

The type system is modularised across several files:
- `type_defs.nim` — Core type definitions (ValueKind, Instruction, Frame, Scope, etc.)
- `value_core.nim` — NaN-boxing implementation and value operations
- `classes.nim` — Class-related utilities
- `instructions.nim` — Instruction helpers and formatting
- `helpers.nim` — Miscellaneous utility functions

### NaN-Boxing

- `Value` is a `bycopy` object with a `raw: uint64` field, using NaN-boxing for compact representation.
- All valid IEEE 754 floats pass through unchanged; non-float values live in the negative quiet NaN space (0xFFF0-0xFFFF prefix).
- Tag constants partition the NaN space:
  - `SPECIAL_TAG` (0xFFF1) — NIL, TRUE, FALSE, VOID, PLACEHOLDER, characters
  - `SMALL_INT_TAG` (0xFFF2) — 48-bit immediate integers
  - `SYMBOL_TAG` (0xFFF3) — Interned symbol indices
  - `POINTER_TAG` (0xFFF4) — Raw pointers
  - `ARRAY_TAG` (0xFFF8) — Heap-allocated arrays
  - `MAP_TAG` (0xFFF9) — Heap-allocated maps
  - `INSTANCE_TAG` (0xFFFA) — Class instances
  - `GENE_TAG` (0xFFFB) — Gene S-expression nodes
  - `REF_TAG` (0xFFFC) — General Reference objects (functions, namespaces, etc.)
  - `STRING_TAG` (0xFFFD) — Heap-allocated strings

### Automatic Reference Counting

- Managed types (tags ≥ 0xFFF8) use automatic reference counting via Nim's `=copy`/`=destroy`/`=sink` hooks.
- The `isManaged` template performs a single-instruction check: `(v.raw and 0xFFF8_0000_0000_0000) == 0xFFF8_0000_0000_0000`.
- `retainManaged`/`releaseManaged` increment/decrement ref counts; objects are destroyed when count reaches zero.
- This replaces explicit retain/release calls for most operations while keeping hot paths allocation-free.

### ValueKind

- `ValueKind` enumerates 60+ variants covering scalars, collections, futures, generators, threads, namespaces, instructions, and more.
- Symbol keys (`Key`) are cached integers indexing into the global symbol table for fast lookup.

## Instruction Families

Instruction opcodes live in `InstructionKind` (`src/gene/types/type_defs.nim`). Key groups:

- **Stack & Scope**: `IkPushValue`, `IkPushNil`, `IkPop`, `IkDup*`, `IkSwap`, `IkOver`, `IkLen`, `IkScopeStart`, `IkScopeEnd`.
- **Variables**: `IkVar`, `IkVarResolve`, `IkVarAssign`, `IkVarResolveInherited`, `IkVarAssignInherited`, plus arithmetic variants (`IkVarAddValue`, `IkVarSubValue`, `IkIncVar`, `IkDecVar`, …).
- **Control Flow**: `IkJump`, `IkJumpIfFalse`, `IkJumpIfMatchSuccess`, `IkLoopStart/End`, `IkContinue`, `IkBreak`, `IkReturn`, `IkTailCall`.
- **Data & Collections**: `IkArrayStart/End`, `IkMapStart/End`, `IkMapSpread`, `IkGene*`, `IkStreamStart/End`, spread instructions, `IkCreateRange`, `IkCreateEnum`.
- **Unified Calls**: `IkUnifiedCall0/1/Kw/Dynamic`, `IkUnifiedMethodCall0/1/2/Kw`, `IkDynamicMethodCall`, `IkCallArgsStart`, `IkCallArgSpread`.
- **Functions & Macros**: `IkFunction`, `IkBlock`, `IkCallInit`, `IkCallerEval`.
- **Classes & Methods**: `IkClass`, `IkSubClass`, `IkNew`, `IkDefineMethod`, `IkDefineConstructor`, `IkResolveMethod`, `IkCallSuperMethod`, `IkCallSuperCtor`, `IkSuper`.
- **Namespaces & Modules**: `IkNamespace`, `IkNamespaceStore`, `IkImport`.
- **Error Handling**: `IkTryStart`, `IkTryEnd`, `IkCatchStart/End`, `IkFinally`, `IkFinallyEnd`, `IkThrow`, `IkCatchRestore`, `IkGetClass`, `IkIsInstance`.
- **Generators**: `IkYield`, `IkResume`.
- **Async & Threading**: `IkAsyncStart`, `IkAsyncEnd`, `IkAwait`, `IkAsync`, `IkSpawnThread`.
- **Selectors**: `IkCreateSelector`, `IkSetMemberDynamic`, `IkAssertNotVoid`, `IkGetMemberOrNil`, `IkGetMemberDefault`.
- **Superinstructions**: `IkPushCallPop`, `IkLoadCallPop`, `IkGetLocal`, `IkSetLocal`, `IkAddLocal`, `IkIncLocal`, `IkDecLocal`, `IkReturnNil/True/False`.

See `src/gene/compiler.nim` for how AST nodes map to these instructions, and `src/gene/vm.nim` for runtime semantics.

## Memory Model & Scope Lifetime

- Frames are pooled; `new_frame` reuses objects when possible to cut allocations.
- Scopes (`ScopeObj`) are manually ref-counted. `IkScopeEnd` calls `scope.free()` which decrements the ref count and only deallocates when it reaches 0.
  ✅ Scope lifetime is correctly managed - async code can safely capture scopes and they won't be freed prematurely.
- Values use automatic reference counting via Nim's `=copy`/`=destroy` hooks for managed types (arrays, maps, instances, genes, strings, references).
- The VM keeps hot paths allocation-free by using immediate values (ints, bools, symbols) that fit in the NaN-boxed 64-bit representation.

## Native Integration

- `src/gene/stdlib.nim` initialises built-in namespaces and registers native functions.
- Standard library modules in `src/gene/stdlib/`:
  - `math.nim` — Mathematical operations
  - `io.nim` — File I/O and async file operations
  - `system.nim` — System-level utilities
- Native functions use `NativeFn`/`NativeMethod` signatures and are stored in class/namespace tables.
- Native macros use `NativeMacroFn` signature and receive unevaluated Gene AST plus caller frame.
- Extensions can be built as shared libraries (see `nimble buildext`) and loaded at runtime via `src/gene/vm/extension.nim`.

## Threading Support

- Worker threads are managed via a thread pool (`THREADS` array, max 64 threads).
- Each thread has its own `VirtualMachine` instance and message channel.
- `IkSpawnThread` spawns code on a worker thread and optionally returns a future for the result.
- Thread messages are serialised/deserialised when crossing thread boundaries to ensure isolation.
- The main thread polls for thread replies during event loop processing (`poll_event_loop`).

## Generators

- Generator functions are defined with `(fn* name [...] ...)` syntax.
- `IkYield` suspends execution and returns a value; `IkResume` continues from the suspension point.
- `GeneratorObj` stores the saved frame, compilation unit, program counter, and scope.
- Generators support `has_next`, `next`, and `peek` operations.

## AOP (Aspect-Oriented Programming)

- Aspects intercept method calls with before/after/around advices.
- `Aspect` objects store advice mappings keyed by parameter names.
- `AopContext` tracks the current interception state during around advice execution.
- Interceptions wrap original callables and delegate to aspect advices.

## Inline Caching

- `InlineCache` objects accelerate symbol and method resolution.
- Each cache stores namespace/class version numbers to detect invalidation.
- On cache hit (matching version), resolution skips the lookup path.
- Caches are attached to `CompilationUnit` and indexed by program counter.

## Example Execution Flow

```
(fn add [a b] (+ a b))
(add 1 2)
```

Compilation emits (simplified):
```
IkStart
IkFunction
IkPop
IkResolveSymbol        add
IkPushValue            1
IkPushValue            2
IkUnifiedCall
IkEnd
```

## Observability & Tooling

- `VM.trace = true` prints the instruction stream as it executes (enabled via CLI `--trace`).
- Instruction and function profilers (`VM.print_profile`, `VM.print_instruction_profile`) help prioritise optimisations.
- GIR hashes plus timestamps make it cheap to spot stale IR during `gene run`.
- `docs/performance.md` tracks benchmarking methodology and ongoing optimisation ideas.

## Gene IR (GIR) Details

- `GIR_VERSION` (currently 22) tracks the IR format version.
- `VALUE_ABI_VERSION` (currently 2) tracks the Value representation version — changed when NaN-boxing layout changes.
- `INSTRUCTION_ABI_VERSION` (currently 3) tracks instruction encoding/layout compatibility.
- Header includes compiler fingerprint, VM ABI marker, timestamp, source hash, and debug flags for cache validation.
- `gene compile` writes GIR files; `gene run` can execute them directly or use cached versions from `build/`.

## Current Pain Points

- Class system lacks exhaustive tests for constructors, inheritance, and keyword arguments.
- Pattern matching infrastructure exists but many `match` forms remain disabled in the test suite.

## See Also

Core documentation:
- [`gir.md`](gir.md) — GIR format and CLI workflows
- [`performance.md`](performance.md) — Hotspot analysis and optimisation roadmap

Current subsystem docs:
- [`generator_functions.md`](generator_functions.md) — Generator implementation

Proposal and design-era docs:
- [`proposals/future/selector_design.md`](proposals/future/selector_design.md) — Selector redesign and future direction
- [`proposals/future/pattern_matching_design.md`](proposals/future/pattern_matching_design.md) — Pattern matching proposal
- [`proposals/future/macro_design.md`](proposals/future/macro_design.md) — Macro system design notes
- [`proposals/future/aop.md`](proposals/future/aop.md) — Aspect-oriented programming concept notes

Extension and tooling:
- [`c_extensions.md`](c_extensions.md) — Building C/Nim extensions
- [`lsp.md`](lsp.md) — Language Server Protocol support
