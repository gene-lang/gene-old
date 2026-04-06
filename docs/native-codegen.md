# Native Code Generation

Gene compiles typed functions to native ARM64/x86-64 machine code via a
three-stage pipeline: **Bytecode -> HIR -> Machine Code**. This document
captures the current state, design principles, and roadmap for expanding
native compilation coverage.

## Pipeline Overview

```
Gene source
  |  parser
  v
AST (Value tree)
  |  compiler  (compiler.nim, compiler/*.nim)
  v
CompilationUnit (bytecode instructions)
  |  bytecode_to_hir.nim
  v
HIR (SSA-form typed IR)
  |  arm64_codegen.nim / x86_64_codegen.nim
  v
Machine code (mmap'd executable memory)
```

**Key files:**

| File | Role |
|------|------|
| `src/gene/native/hir.nim` | HIR types, builder, pretty-printer |
| `src/gene/native/bytecode_to_hir.nim` | Bytecode -> HIR conversion + eligibility check |
| `src/gene/native/arm64_codegen.nim` | ARM64 machine code generation |
| `src/gene/native/x86_64_codegen.nim` | x86-64 machine code generation |
| `src/gene/native/runtime.nim` | JIT memory allocation, compile dispatch |
| `src/gene/native/trampoline.nim` | Native -> VM callback bridge |
| `src/gene/vm/native.nim` | `try_native_call`, argument marshaling |

## Current State

### What compiles natively today

Typed functions with primitive parameters that use:

- **Arithmetic**: `+`, `-`, `*`, `/`, `%`, unary `-`
- **Comparisons**: `<`, `<=`, `>`, `>=`, `==`, `!=`
- **Boolean ops**: `not`, `and`, `or`
- **Control flow**: `if`/`else`, `while` loops, `break`, `continue`
- **Local variables**: `var`, assignment, `+=1`/`-=1`
- **Recursive calls**: direct self-recursion via `bl` (ARM64) / `call` (x86-64)
- **VM callbacks**: calls to other typed functions via trampoline

### HIR type system

```
HtVoid    - no value (statements)
HtBool    - boolean (stored as i64: 0 or 1) [internal only]
HtI64     - 64-bit signed integer
HtF64     - 64-bit floating point
HtPtr     - raw pointer (reserved, unused)
HtString  - pointer to Gene String payload
HtValue   - NaN-boxed Gene Value (64-bit, opaque to native code)
```

**Note:** `HtBool` is an internal computation type only. Comparisons produce
`HtBool` and branches consume it, but `Bool` cannot appear as a function
parameter or return type at the native boundary. A Gene `Bool` parameter
would need to be marshaled as `HtI64` (0/1) or `HtValue`.

Several HIR op kinds are defined in the `HirOpKind` enum but not yet
implemented in either codegen backend: `HokRetVoid`, `HokPhi`,
`HokCallIndirect`, `HokBoxI64`, `HokBoxF64`, `HokBoxBool`, `HokUnboxI64`,
`HokUnboxF64`, `HokUnboxBool`. These are reserved for future tiers and
will cause a codegen error if encountered.

### Performance

On typed functions (fibonacci, tight while loops), native compilation
delivers **80-90x speedup** over the VM interpreter.

## Design Principles

1. **Gradual widening.** Start with the tightest, most provably-correct
   subset and widen eligibility incrementally. Every new instruction or
   type we support must have a clear correctness argument.

2. **HtValue as the escape hatch.** Any Gene value that doesn't map to a
   primitive HIR type is represented as `HtValue` (raw NaN-boxed bits).
   Native code can hold, pass, and return `HtValue` without understanding
   its contents. Operations on `HtValue` go through the VM trampoline.

3. **Trampoline-first for new types.** When adding support for a new type
   (Array, Map, instance), start by treating it as `HtValue` and routing
   all operations through `HokCallVM`. Only inline hot operations after
   profiling proves the trampoline is the bottleneck.

4. **Ref-counting correctness.** Arrays, maps, and strings are ref-counted.
   Native code must not create dangling references. The safest model is to
   keep values as NaN-boxed `HtValue` and let the VM/trampoline handle
   retain/release. Inlined operations must maintain ref-count invariants.

5. **No speculative optimization.** Only compile what we can prove is
   correct. If a function might not be eligible at runtime (e.g., dynamic
   dispatch), fall back to the VM. The `native_failed` flag prevents
   repeated compilation attempts.

## Roadmap

### Tier 1: Value-typed parameters (next)

**Goal:** Allow functions that accept/return Array, Map, or any non-primitive
type to be native-compiled, with operations on those values going through the
trampoline.

**What changes:**

- Relax `isNativeEligible` to allow `HtValue` parameters (currently rejects
  anything not in `{HtI64, HtF64, HtString}`).
- Map `BUILTIN_TYPE_ARRAY_ID`, `BUILTIN_TYPE_MAP_ID`, and unknown type IDs
  to `HtValue` in `typeIdToHir`.
- Marshal `HtValue` args as raw `uint64` bits (already supported by
  `CatValue`/`CrtValue` in the trampoline).
- Handle ref-counting: `retain()` on entry, let the VM's `=destroy` handle
  release on scope exit.

**Example unlocked:**

```gene
(fn sum_array [arr: Array] -> Int
  (var total 0)
  (var i 0)
  (while (i < (arr .size))
    (total = (total + (arr .get i)))
    (i = (i + 1)))
  total)
```

The `while` loop, variable updates, and arithmetic run native. `.size` and
`.get` bounce through the trampoline to existing `VkNativeFn` implementations.

### Tier 2: Method dispatch from native code

**Goal:** Allow native code to call methods on value types (String, Array,
Map) and class instances.

**What changes:**

- In `bytecode_to_hir.nim`, handle `IkUnifiedMethodCall0/1/2` by resolving
  the method at HIR-conversion time (when the receiver type is known) and
  emitting `HokCallVM` with a `CallDescriptor` pointing to the method's
  callable.
- For value-type methods (e.g., `string.length`, `array.push`), the callable
  is a `VkNativeFn` — the trampoline calls it directly.
- For user-defined methods on classes, the callable is a `VkFunction` — the
  trampoline calls `exec_function` which may itself attempt native compilation
  (recursive native dispatch).

**Design note:** Method resolution happens at HIR-conversion time, not at
machine-code execution time. This means the method must be resolvable from
the receiver's static type. If the receiver is `HtValue` (dynamic type), we
cannot resolve the method and must fall back to the VM.

### Tier 3: Instance methods and `self`

**Goal:** Allow methods on user-defined classes to be native-compiled.

**What changes:**

- The compiler already prepends `self` as the first parameter in the matcher.
  `self` would be passed as `HtValue` (NaN-boxed instance pointer).
- Relax eligibility to allow `self` as an `HtValue` parameter.
- Wire `try_native_call` into `IkUnifiedMethodCall0/1/2` handlers in
  `exec.nim`, building the args array as `[obj] + remaining_args`.
- Method bodies that only do arithmetic on primitive parameters (not
  accessing `self` fields) work immediately.
- Field access (`self .x`) requires Tier 4.

### Tier 4: Instance field access

**Goal:** Native code can read and write instance fields without trampolining.

**What changes:**

- Add HIR operations: `HokGetField(instance, field_index)`,
  `HokSetField(instance, field_index, value)`.
- At HIR-conversion time, resolve field names to member indices using the
  class definition.
- In codegen, emit loads/stores from the `VkInstance` member array:
  - Unbox the instance pointer from `HtValue`
  - Index into `instance.members[field_index]` (known offset)
  - Box/unbox the field value based on type annotations if available
- Maintain ref-count invariants for `HokSetField` (release old, retain new).

**Example unlocked:**

```gene
(class Point
  (ctor [x: Int y: Int] ...)
  (method magnitude_sq [] -> Int
    (+ (* (.x) (.x)) (* (.y) (.y)))))
```

### Tier 5: Inlined collection operations

**Goal:** Inline the hottest Array/String operations to avoid trampoline
overhead in tight loops.

**Candidate operations (in priority order):**

| Operation | HIR op | What it does |
|-----------|--------|-------------|
| `(arr .size)` | `HokArrayLen` | Read `ArrayObj.arr.len` |
| `(arr .get i)` | `HokArrayGet` | Bounds check + `ArrayObj.arr[i]` |
| `(str .size)` | `HokStringLen` | Read `String.str.len` |
| `(arr .push v)` | `HokArrayPush` | Append to `ArrayObj.arr` |
| `(str ++ str)` | `HokStringConcat` | Allocate + copy |

**Design considerations:**

- **Bounds checking.** `HokArrayGet` must emit a bounds check. On failure,
  it should jump to an error handler that calls the VM's `not_allowed` path.
- **Ref-counting.** `HokArrayPush` must `retain` the pushed value.
  `HokArrayGet` returns a borrowed reference (no retain needed if consumed
  immediately, but must retain if stored).
- **Memory layout coupling.** Inlining requires knowing the exact byte
  offsets of `ArrayObj.arr.len`, `ArrayObj.arr.data`, `String.str.len`, etc.
  These must be verified with `static: assert offsetof(...)` to catch layout
  changes.
- **Mutation.** Only `HokArrayPush` and `HokSetField` mutate. Must check
  `frozen` flag before mutation. Frozen arrays/maps should fall back to
  the trampoline or raise an error.

### Tier 6: For loops and iterators

**Goal:** Native compilation of `(for x in collection body)`.

This requires:
- `IkRepeatInit` / `IkRepeatDecCheck` support in bytecode_to_hir
- Iterator protocol: `iter()`, `has_next()`, `next()` calls
- For simple counted loops (`repeat N`), can be lowered to a native
  counter + branch without iterator overhead
- For collection iteration, iterator calls go through trampoline initially,
  with potential inlining of array iterators in a later pass

### Beyond: Speculative ideas

- **Polymorphic inline caches in native code.** The VM already has inline
  caches for method dispatch. Native code could embed guarded dispatch:
  check receiver class, branch to cached method entry, deopt to VM on miss.
- **Escape analysis.** If a local array never escapes the function, skip
  ref-counting and allocate on the stack.
- **Loop-invariant code motion.** Hoist `.size` calls out of loops when the
  array is not mutated in the loop body.
- **Register allocation.** The ARM64 codegen already has a simple read cache
  using X9-X15. A proper linear-scan allocator over HIR SSA form would
  reduce stack traffic further.

## Eligibility Check

A function is native-eligible if:

1. All parameters have type annotations
2. Parameter types map to supported HIR types (currently `HtI64`, `HtF64`,
   `HtString`; Tier 1 adds `HtValue` for others)
3. All bytecodes in the function body are in the whitelist
4. The bytecodes successfully convert to HIR (trial conversion)
5. The HIR passes validation (no unsupported ops)

The check is conservative: if in doubt, reject and fall back to the VM.
False negatives (missing a native-eligible function) are acceptable; false
positives (compiling something incorrectly) are not.

## Calling Conventions

### Native function signature

```
result: int64 = fn(ctx: ptr NativeContext, arg0: int64, ..., argN: int64)
```

- First argument is always `ctx` (pointer to `NativeContext` struct)
- All arguments are `int64` (uniform ABI):
  - `Int` values are passed directly
  - `Float` values are bitcast (`float64` -> `int64`)
  - `String` values are the payload pointer (lower 48 bits of NaN-boxed value)
  - `Value` types (Array, Map, instance) are raw NaN-boxed bits
- Return value is `int64`, unboxed based on the function's return type
- **Argument limit:** ARM64 passes args in X1-X7 (7 user args max), x86-64
  uses RDI(ctx)+RSI,RDX,RCX,R8,R9 (5 user args max). Functions exceeding
  these limits fall back to the VM.

### NativeContext

```nim
NativeContext = object
  vm: ptr VirtualMachine         # Back-reference to VM
  trampoline: pointer            # native_trampoline function pointer
  descriptors: ptr UncheckedArray[CallDescriptor]
  descriptor_count: int32
```

Used by native code to call back to the VM via the trampoline for operations
it cannot handle natively (method calls, complex dispatch, etc.).

### Architecture-specific notes

**ARM64** has a read cache that maps 7 callee-saved registers (X9-X15) to
recently-accessed HIR registers, avoiding redundant stack loads. The cache is
invalidated on function calls (`bl`) since those registers are caller-saved.
This gives ARM64 a measurable advantage on register-heavy code like fibonacci.

**x86-64** does not have this cache and uses a simpler load-from-stack model
for all operations. Adding a similar cache using R12-R15 is a future option.

### VM Trampoline

When native code needs to call a Gene function or native method:

1. Native code loads args into a stack-allocated `int64` array
2. Calls `trampoline(ctx, descriptor_index, args_ptr, argc)`
3. Trampoline unboxes args per `CallDescriptor.argTypes`
4. Calls the target function/method via the VM
5. Boxes the result per `CallDescriptor.returnType`
6. Returns `int64` to native code
