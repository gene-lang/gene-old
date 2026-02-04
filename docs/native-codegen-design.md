# Gene Native Code Generation Design

## Overview

This document describes the design for compiling typed Gene functions to native machine code. The goal is to achieve 10-50x performance improvement for hot, fully-typed functions while maintaining seamless interop with the dynamic VM.

**Scope**: Start with Fibonacci as proof-of-concept, generalize to other typed functions.

## 1. Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Gene Source (.gene)                              │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Parser (parser.nim)                              │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Compiler (compiler.nim)                          │
│   • Extract type annotations                                         │
│   • Mark native-eligible functions                                   │
│   • Generate bytecode (existing) AND HIR (new)                      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
┌───────────────────────────┐   ┌───────────────────────────────────┐
│  Bytecode (existing)      │   │  HIR (new: native/hir.nim)        │
│  CompilationUnit          │   │  SSA-form typed IR                │
└───────────────────────────┘   └───────────────────────────────────┘
                    │                       │
                    ▼                       ▼
┌───────────────────────────┐   ┌───────────────────────────────────┐
│  VM Interpreter           │   │  Native Codegen (x86-64)          │
│  (vm.nim)                 │   │  (native/x86_64.nim - future)     │
└───────────────────────────┘   └───────────────────────────────────┘
                    │                       │
                    └───────────┬───────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Unified Execution                                │
│   • Native functions called directly when types match                │
│   • VM handles dynamic fallback                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## 2. HIR (High-level Intermediate Representation)

### 2.1 Design Principles

1. **SSA Form**: Each value assigned exactly once
2. **Typed**: Every register has a known type (i64, f64, bool, Value)
3. **Simple**: Minimal instruction set, easy to codegen
4. **Boxed Boundary**: Unboxed inside functions, boxed at VM boundary

### 2.2 Types

```nim
HirType = enum
  HtVoid     # No value
  HtBool     # Boolean (0 or 1)
  HtI64      # 64-bit integer
  HtF64      # 64-bit float
  HtPtr      # Pointer (for objects)
  HtValue    # NaN-boxed Gene Value
```

### 2.3 Core Operations (for fib)

| Category | Operations | Description |
|----------|------------|-------------|
| Constants | `const.i64`, `const.bool` | Load immediate values |
| Arithmetic | `add.i64`, `sub.i64` | Integer arithmetic |
| Comparison | `le.i64`, `lt.i64`, etc. | Compare, produce bool |
| Control | `br`, `jump`, `ret` | Branches and returns |
| Calls | `call @fn(args)` | Direct function call |
| Boxing | `box.i64`, `unbox.i64` | NaN-boxing conversion |

### 2.4 Example: Fibonacci HIR

```
function @fib(%0: i64) -> i64 {
entry:  ; L0
    %1 = const.i64 1
    %2 = le.i64 %0, %1
    br %2, L1, L2
then:  ; L1
    ret %0
else:  ; L2
    %3 = sub.i64 %0, %1
    %4 = call @fib(%3) : i64
    %5 = const.i64 2
    %6 = sub.i64 %0, %5
    %7 = call @fib(%6) : i64
    %8 = add.i64 %4, %7
    ret %8
}
```

## 3. Bytecode → HIR Conversion

### 3.1 Strategy

Convert Gene bytecode to HIR for typed functions. This happens after normal compilation.

### 3.2 Bytecode Mapping (for fib operations)

| Gene Bytecode | HIR Equivalent | Notes |
|---------------|----------------|-------|
| `VarLeValue 0, 1` | `%r = le.i64 %param0, 1` | Optimized compare |
| `VarSubValue 0, 1` | `%r = sub.i64 %param0, 1` | Optimized subtract |
| `JumpIfFalse → N` | `br %cond, next, N` | Conditional branch |
| `Jump → N` | `jump N` | Unconditional jump |
| `Add` | `%r = add.i64 %a, %b` | Pop two, push result |
| `ResolveSymbol + UnifiedCall1` | `%r = call @fn(%arg)` | Direct call |
| `VarResolve var[0]` | `%r = copy %param0` | Variable read |
| `End` | `ret %top` | Return top of stack |

### 3.3 Conversion Algorithm

```
Input: CompilationUnit with typed function signature
Output: HirFunction

1. Create HirBuilder with return type from signature
2. Add parameters from function signature
3. Simulate bytecode execution on abstract stack:
   - Track which register holds each stack slot
   - Convert each bytecode op to HIR equivalent
   - At branch points, create new HirBlocks
4. Handle control flow:
   - JumpIfFalse creates branch + two successor blocks
   - Jump creates unconditional edge
   - End/return finalizes block
5. Return HirFunction

Key insight: VarLeValue, VarSubValue, VarAddValue are already optimized
in bytecode - they map 1:1 to HIR operations.
```

### 3.4 Type Eligibility Check

A function is native-eligible if:
1. All parameters have explicit type annotations
2. Return type is annotated
3. All types are primitive (Int, Float, Bool) - no objects yet
4. No dynamic operations (eval, dynamic dispatch)

```nim
proc isNativeEligible(fn: FunctionDefInfo): bool =
  # Check all params have types
  for param in fn.params:
    if param.typ.isNil or param.typ.kind == TkAny:
      return false
  # Check return type
  if fn.returnType.isNil or fn.returnType.kind == TkAny:
    return false
  # Check types are primitive
  for param in fn.params:
    if param.typ.kind notin {TkInt, TkFloat, TkBool}:
      return false
  return true
```

## 4. x86-64 Code Generation

### 4.1 Approach: Template-Based

Start with a simple template-based approach (no register allocation):

1. Each HIR operation has a fixed code template
2. Use stack for intermediate values (simple but inefficient)
3. Later: add register allocation for better performance

### 4.2 Calling Convention

**Boxed Wrapper** (for VM interop):
- Input: `%rdi` = NaN-boxed Value
- Output: `%rax` = NaN-boxed Value
- Unbox at entry, box at exit

**Internal Convention** (for native-to-native calls):
- Input: `%rdi, %rsi, %rdx, %rcx, %r8, %r9` = raw int64/float64
- Output: `%rax` = raw int64/float64
- No boxing overhead for recursive calls

### 4.3 Code Templates (x86-64)

```asm
# const.i64 <value>
mov     $<value>, %rax
push    %rax

# add.i64
pop     %rcx        # right operand
pop     %rax        # left operand
add     %rcx, %rax
push    %rax

# sub.i64
pop     %rcx        # right operand
pop     %rax        # left operand
sub     %rcx, %rax
push    %rax

# le.i64 (produces 0 or 1)
pop     %rcx        # right
pop     %rax        # left
cmp     %rcx, %rax
setle   %al
movzx   %al, %rax
push    %rax

# br %cond, then, else
pop     %rax
test    %rax, %rax
jz      <else_label>
jmp     <then_label>

# call @fn(%arg)
pop     %rdi        # first arg
call    _gene_fn
push    %rax

# ret %value
pop     %rax
# epilogue...
ret

# box.i64 (int64 -> Value)
pop     %rax
and     $0x0000FFFFFFFFFFFF, %rax   # PAYLOAD_MASK
or      $0xFFF2000000000000, %rax   # SMALL_INT_TAG
push    %rax

# unbox.i64 (Value -> int64)
pop     %rax
and     $0x0000FFFFFFFFFFFF, %rax   # PAYLOAD_MASK
# Sign extend if negative
bt      $47, %rax
jnc     .Lpos
or      $0xFFFF000000000000, %rax
.Lpos:
push    %rax
```

### 4.4 Fibonacci Assembly (Optimized)

With proper register allocation, fib becomes:

```asm
_gene_fib_internal:
    ; %rdi = n (raw int64)
    ; returns %rax = result (raw int64)

    cmp     $1, %rdi
    jg      .Lrecurse
    mov     %rdi, %rax
    ret

.Lrecurse:
    push    %rbx
    mov     %rdi, %rbx          ; save n

    lea     -1(%rbx), %rdi      ; n - 1
    call    _gene_fib_internal
    push    %rax                ; save fib(n-1)

    lea     -2(%rbx), %rdi      ; n - 2
    call    _gene_fib_internal

    pop     %rcx                ; fib(n-1)
    add     %rcx, %rax          ; fib(n-1) + fib(n-2)

    pop     %rbx
    ret

_gene_fib_boxed:
    ; %rdi = NaN-boxed Value
    ; returns %rax = NaN-boxed Value

    ; Unbox
    mov     %rdi, %rax
    and     $0x0000FFFFFFFFFFFF, %rax
    bt      $47, %rax
    jnc     .Lunbox_pos
    or      $0xFFFF000000000000, %rax
.Lunbox_pos:
    mov     %rax, %rdi

    ; Call internal
    call    _gene_fib_internal

    ; Box result
    and     $0x0000FFFFFFFFFFFF, %rax
    or      $0xFFF2000000000000, %rax
    ret
```

## 5. VM Integration

### 5.1 Native Function Registry

```nim
type
  NativeFunctionRegistry* = object
    functions*: Table[string, NativeFunction]

var nativeRegistry* = NativeFunctionRegistry()

proc registerNative*(name: string, fn: NativeFunction) =
  nativeRegistry.functions[name] = fn

proc lookupNative*(name: string): ptr NativeFunction =
  if name in nativeRegistry.functions:
    return addr nativeRegistry.functions[name]
  return nil
```

### 5.2 VM Dispatch (Modified)

In `vm.nim`, modify function call handling:

```nim
proc callFunction(vm: ptr VirtualMachine, fn: Value, args: seq[Value]): Value =
  let fdef = fn.ref.fn

  # Check for native version
  let native = lookupNative(fdef.name)
  if native != nil and argsMatchTypes(args, native.hir.params):
    # Fast path: call native code
    return native.boxedWrapper(args.toUncheckedArray, args.len.int32)

  # Slow path: interpret bytecode
  # ... existing code ...
```

### 5.3 Compilation Pipeline

```nim
proc compileToNative*(cu: CompilationUnit, fnType: FunctionType): NativeFunction =
  # 1. Convert bytecode to HIR
  let hir = bytecodeToHir(cu, fnType)

  # 2. Optimize HIR (future)
  # let optimized = optimizeHir(hir)

  # 3. Generate machine code
  let code = generateX86_64(hir)

  # 4. Make executable
  let entryPoint = makeExecutable(code)

  # 5. Create boxed wrapper
  let wrapper = createBoxedWrapper(entryPoint, fnType)

  result = NativeFunction(
    name: fnType.name,
    hir: hir,
    machineCode: code,
    entryPoint: entryPoint,
    boxedWrapper: wrapper
  )
```

## 6. Implementation Roadmap

### Phase 1: HIR Foundation (Week 1)
- [x] Define HIR data structures (`native/hir.nim`)
- [ ] Build fib HIR manually (for testing)
- [ ] HIR pretty-printer
- [ ] HIR validation

### Phase 2: Bytecode → HIR (Week 2-3)
- [ ] Type extraction from function definitions
- [ ] Abstract stack simulation
- [ ] Handle fib operations: `VarLeValue`, `VarSubValue`, `Add`, branches
- [ ] Control flow graph construction

### Phase 3: x86-64 Codegen (Week 3-4)
- [ ] Template-based code generation
- [ ] Stack-based evaluation (simple but slow)
- [ ] Machine code buffer management
- [ ] Make memory executable (mmap/VirtualAlloc)

### Phase 4: Integration (Week 4-5)
- [ ] Native function registry
- [ ] VM dispatch to native code
- [ ] Boxed wrapper generation
- [ ] Testing with fib benchmarks

### Phase 5: Optimization (Future)
- [ ] Register allocation
- [ ] Peephole optimization
- [ ] Inline caching for indirect calls
- [ ] SIMD for array operations

## 7. Performance Targets

| Metric | Current VM | Native (Phase 3) | Native (Optimized) |
|--------|------------|------------------|-------------------|
| fib(24) time | ~400ms | ~40ms | ~4ms |
| Calls/sec | ~600K | ~6M | ~60M |
| Overhead per call | ~1000 cycles | ~100 cycles | ~10 cycles |

## 8. Files

| File | Purpose |
|------|---------|
| `src/gene/native/hir.nim` | HIR data structures and builder |
| `src/gene/native/hir_convert.nim` | Bytecode → HIR conversion (future) |
| `src/gene/native/x86_64.nim` | x86-64 code generation (future) |
| `src/gene/native/registry.nim` | Native function registry (future) |
| `docs/native-codegen-design.md` | This document |

## 9. References

- [NaN Boxing in LuaJIT](http://lua-users.org/wiki/NanBoxing)
- [Cranelift IR Design](https://github.com/bytecodealliance/wasmtime/tree/main/cranelift)
- [V8 Turbofan Compiler](https://v8.dev/docs/turbofan)
- [Simple JIT in C](https://eli.thegreenplace.net/2017/adventures-in-jit-compilation-part-1-an-interpreter/)

