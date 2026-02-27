# Phase 1: Architecture Comparison - Research

**Researched:** 2026-02-27
**Domain:** Gene programming language implementation comparison (gene-old vs gene)
**Confidence:** HIGH

---

## Summary

This research compares two Gene language implementations in Nim:
- **gene-old** (`/Users/gcao/gene-workspace/gene-old`): The current working implementation. Has a full-featured bytecode VM, GIR cache, AOP system, type checking, threading, and extension loader. Performance: ~3.76M function calls/sec (optimized build).
- **gene** (`/Users/gcao/gene-workspace/gene`): A newer, redesigned implementation. Introduces AIR (Artisan Intermediate Representation) bytecode, a capability/quota system, deterministic replay, WASM target, structured-output error diagnostics, and a cleaner type system with fewer heap-allocated types.

The primary finding is that `gene` represents a deliberate architectural evolution from `gene-old`. It has a cleaner separation between IR and execution, a more principled memory model, a formal capability system, and several AI-first features (tool calls, replay, quotas) that `gene-old` lacks. However, `gene-old` retains the richer language surface (AOP aspects, full class hierarchy with aspect interception, GIR cache, more complete stdlib). The improvements are complementary, not competitive.

**Primary recommendation:** Cherry-pick specific architectural improvements from `gene` into `gene-old`. Do not merge or rewrite. Apply in priority order: (1) structured error diagnostics, (2) stable native extension ABI, (3) bytecode verifier, (4) explicit upvalue capture, (5) capability/quota system.


---

## Comparison Matrix

| Area | gene-old Approach | gene Approach | gene Better? | Applicable to gene-old? |
|------|-------------------|---------------|-------------|------------------------|
| **Value representation** | NaN-boxing with 6 managed tags (FFF8-FFFD), inline ref-counts per struct, `ptr T` for heap types | NaN-boxing with single sign+QNaN bit pattern, external heap table (`gHeapObjects`), Nim `ref object` for heap | Mixed. gene-old slightly faster per deref; gene simpler but requires global table lookup | LOW effort gain, design tradeoff |
| **Instruction set** | Named `InstructionKind` enum, variable-length operands via `arg0`/`arg1`/`arg2` stored as `Value`, labels for jumps | Fixed-width `AirInst` struct (op u8, mode u8, a u8, b u32, c u32, d u32), integers for operands | gene fixed-width encoding is more cache-friendly and easier to serialize. gene-old Value-operand approach wastes space | HIGH value, HIGH effort |
| **IR/bytecode format** | `CompilationUnit` with instruction seq and GIR serialization; label-based jumps patched at end | `AirModule` with string/symbol/constant pools, `AirFunction` per callable, integer IP jumps | gene pooled module structure is cleaner and GC-friendly | MEDIUM value, HIGH effort |
| **Bytecode verifier** | None - trust compiler output | `air_verify.nim` - stack-depth analysis verifies each function before execution | HIGH value - catches compiler bugs early | HIGH value, MEDIUM effort |
| **Dispatch loop** | `computedGoto` case-switch in giant `exec()` proc | Normal case-switch in `executeFunction()` per-frame, no computedGoto | gene-old faster due to computedGoto | gene-old already better here |
| **Frame model** | Fixed 256-element `stack: array[256, Value]`, `Frame = ptr FrameObj`, pooled frames | Dynamic `stack: seq[Value]` + `locals: seq[Value]` in `FrameCtx` | gene-old fixed stack faster; gene dynamic safer | gene-old wins on perf |
| **Variable storage** | Scope chain: `ScopeTracker` + `ScopeObj.members`, scope-indexed by parent depth + local index | `locals: seq[Value]` in frame (flat, slot-indexed), `upvalues: OrderedTable[string, Value]` for closures | gene flat locals avoid scope-chain traversal for common cases | HIGH value: flat locals for non-captured vars |
| **Upvalue/closure** | Closures capture entire parent scope via ref-counted `Scope` pointer | Upvalue symbols listed explicitly at compile time; only captured names copied into `FunctionObj.upvalues` | gene explicit upvalue list more precise, avoids capturing entire parent scopes | HIGH value, MEDIUM effort |
| **Capability system** | None | `CapabilityScope`, `OpCapEnter/OpCapExit/OpCapAssert`, stack of scopes | Enables sandboxing; gene-old has no equivalent | HIGH value for AI-first use cases |
| **Quota / resource limits** | None | `VmQuotaConfig` (CPU steps, heap objects, wall clock, tool calls), `OpQuotaSet/OpQuotaCheck` | Enables safe untrusted code execution | HIGH value for AI-first use cases |
| **Structured diagnostics** | String exceptions + REPL-on-error fallback | JSON-envelope error objects with code, severity, stage, span, hints, repair_tags | gene structured errors are machine-parseable; critical for tooling | HIGH value, LOW effort |
| **Deterministic replay** | None | `OpDetSeed/OpDetRand/OpDetNow`, `replayLog`, `replayMode`/`replayCursor` on `Vm` | Enables reproducible execution for AI agents | MEDIUM value, MEDIUM effort |
| **Checkpoint / resume** | None | `OpCheckpointHint/OpCheckpointAndExit`, `resumeVmCheckpoint`, snapshot of frame state | Enables long-running agent tasks to pause/resume | MEDIUM value, HIGH effort |
| **Tool call system** | None | `OpToolPrep/OpToolCall/OpToolAwait/OpToolResultUnwrap`, `ToolSchema`, `ToolHandler` | Native LLM tool-call protocol in VM | LOW applicability - gene-old needs major redesign |
| **WASM target** | None | `when defined(gene_wasm)` guards throughout, `gene_wasm.nim`, `wasm_host_abi.nim` | Enables browser/embedded execution | MEDIUM value, HIGH effort |
| **Native ABI (FFI)** | `dynlib` extension loading (half-working per CONCERNS.md), statically imported in vm.nim | `AirNativeFn` (C ABI proc), `GeneHostApi`, `AirNativeRegistration`, `native_abi.nim` | gene ABI is more stable (C calling convention), enables out-of-process extensions | HIGH value, MEDIUM effort - fixes known tech debt |
| **Module system** | `Namespace`-based, `import` resolves to namespace objects, partial | `AirModule.moduleCache` + `moduleExportCache` keyed by path, `OpImport/OpExport` opcodes | Both incomplete; gene path-keyed cache is cleaner | MEDIUM value, MEDIUM effort |
| **Type system** | ~100+ `ValueKind` variants, gradual typing with `TypeDesc`/`TypeId`, full type checker | Lean `ValueKind` (10 variants) + `HeapKind` (15 variants) + richer compile-time `TypeDesc` | gene-old richer type surface; gene simpler runtime types | gene-old already more complete |
| **AOP** | `Aspect`, `Interception`, `AopContext`, before/after/around/invariant advices | Not present | gene-old unique and valuable | gene already lacks this |
| **Async** | `asyncdispatch` + event-loop polling every 100 instructions, `FutureObj` with Nim future | `OpAsyncBegin/OpAsyncEnd/OpAwait`, future wrapping in VM | Both poll-based; similar approach | gene-old approach functionally equivalent |
| **Parser** | Full Gene parser with macro dispatch table, regex support, 1648 lines, parses to Value | Typed AST (`AstNode` with `AstKind`), produces `Program`, feeds into compiler, 939 lines | gene typed AST cleaner for compiler consumption | MEDIUM value - gene more maintainable |
| **Testing** | `nimble test` + `testsuite/run_tests.sh`; flat `tests/test_*.nim` files | Directory-organized test suites (`test_vm/`, `test_compiler/`, etc.) | gene directory structure cleaner for large suites | LOW effort improvement |
| **Extension loading** | Statically imported `genex/*` in `vm.nim` (known tech debt) | `ffi.nim` with `dynlib` + stable `GeneHostApi` ABI | gene approach is correct - fixes known gene-old tech debt | HIGH value |


---

## High-Value Improvements

Ranked by impact-to-effort ratio:

### 1. Structured Diagnostic Errors (HIGH impact, LOW effort)

**What gene does:** Error values are JSON objects with `code`, `severity`, `stage`, `span` (file/line/col), `message`, `hints`, and `repair_tags`. A `makeDiagnosticMessage` helper builds these. Errors at runtime produce typed codes like `AIR.ARITH.DIV_ZERO`, `AIR.OOP.METHOD_NOT_FOUND`.

**What gene-old does:** Errors are plain string exceptions. `raise new_exception(types.Exception, ...)` produces unstructured strings. REPL-on-error fallback is a workaround.

**Why it matters:** Machine-parseable errors enable better IDE integration, AI-assisted debugging, and automated repair suggestions. The gene-old CONCERNS.md already notes the REPL-on-error fallback is fragile.

**How to apply:** Add `make_diagnostic_message(code, message, stage, file, line, col, hints)` helper. Wrap all `raise new_exception` calls at runtime boundaries to produce structured JSON in the message. No instruction set changes required.

**Key gene reference:** `/Users/gcao/gene-workspace/gene/src/vm/core.nim` lines 268-387 (makeDiagnosticMessage, inferDiagCode, vmRuntimeError, vmDiagnostic).

---

### 2. Stable Native Extension ABI (HIGH impact, MEDIUM effort)

**What gene does:** `AirNativeFn` is a plain C-callable `proc(ctx, args, argc, out_result, out_error): cint`. `GeneHostApi` provides a registration struct. Extensions loaded via `dynlib` call `registerNative*` through the host API. The ABI version constant (`GeneAbiVersion = 1`) enables compatibility checking.

**What gene-old does:** Extensions are statically imported in `vm.nim` as a workaround (documented #1 tech debt in CONCERNS.md: "Temporarily import http and sqlite modules until extension loading is fixed").

**Why it matters:** Directly fixes the top tech debt item. Enables modular deployment and third-party extensions without recompiling gene-old.

**How to apply:**
1. Define a `GeneExtensionAbi` C-compatible header (copy from `native_abi.nim`)
2. Implement `load_extension(path: string)` in the VM that `dynopen`s the library and calls `gene_init(host_api)`
3. Remove the static imports from `vm.nim`
4. Audit `genex/` modules to confirm they can be built as shared libraries

**Key gene reference:** `/Users/gcao/gene-workspace/gene/src/native_abi.nim`, `/Users/gcao/gene-workspace/gene/src/ffi.nim`.

---

### 3. Bytecode Verifier (HIGH impact, MEDIUM effort)

**What gene does:** `air_verify.nim` implements stack-depth analysis. For each function, it walks all control flow paths and verifies the stack depth is consistent at every join point. Calls `stackDelta(inst)` per instruction to track depth. Catches compiler bugs before execution starts.

**What gene-old does:** No verification. A compiler bug producing malformed bytecode causes a runtime crash or silent corruption.

**Why it matters:** gene-old's CONCERNS.md notes "high regression risk in core execution paths." A verifier catches these in CI before they hit users. Also essential before attempting instruction set changes.

**How to apply:** Build `verify_compilation_unit(cu: CompilationUnit): VerifyResult`. Walk `cu.instructions`, model the stack depth using a `stack_delta` proc per instruction kind, check jump targets are valid instruction addresses. Hook into the compile pipeline and GIR load path. Medium effort, high safety return.

**Key gene reference:** `/Users/gcao/gene-workspace/gene/src/air_verify.nim`.

---

### 4. Explicit Upvalue Capture List (MEDIUM impact, MEDIUM effort)

**What gene does:** `AirFunction.upvalueSymbols` lists symbol IDs captured by the function. At instantiation, only those named symbols are copied from the parent frame into `FunctionObj.upvalues`. No entire scope is retained after the parent function returns.

**What gene-old does:** Closures capture `parent_scope: Scope` which retains the entire parent scope alive via ref-counting. This is the known "scope lifetime" memory issue mentioned in CLAUDE.md and causes allocation pressure documented in CONCERNS.md.

**Why it matters:** Addresses the "manual memory management - be careful with scope lifetimes" warning directly. Reduces memory pressure and makes memory behavior predictable.

**How to apply:** At compile time, identify which variables in a closure body are free variables (referenced but not locally defined). Store this set in `Function.captured_names`. At runtime during function instantiation in the VM, copy only those names from the parent scope into a flat map on the closure object, then release the scope reference.

**Key gene reference:** `FunctionObj.upvalueNames`, `FunctionObj.upvalues`, `instantiateFunctionValue` in `/Users/gcao/gene-workspace/gene/src/vm/core.nim`.

---

### 5. Flat Locals vs Scope Chain (MEDIUM impact, MEDIUM effort)

**What gene does:** Every function frame has `locals: seq[Value]` with pre-allocated slots. `OpLoadLocal`/`OpStoreLocal` use integer slot indices - O(1) and cache-friendly. Only captured variables use the upvalue mechanism.

**What gene-old does:** All variables go through `ScopeTracker` + `ScopeObj.members`. Looking up a variable requires finding `local_index` and traversing `parent_index` parent scopes. Even simple local variables pay this traversal cost.

**Why it matters:** The scope-chain walk is a known hotspot. gene's local slot approach eliminates it for the common case (non-captured variables).

**How to apply:** Add a `locals: seq[Value]` field to `FrameObj`. In the compiler, emit new `IkLocalLoad slot` / `IkLocalStore slot` instructions for non-captured locals. Captured variables continue using the existing scope tracker path. The compiler's `ScopeTracker` already distinguishes which variables escape (become upvalues). Non-escaping vars get flat slots.

---

### 6. Capability and Quota System (HIGH impact, HIGH effort)

**What gene does:**
- `CapabilityScope = OrderedTable[string, seq[string]]` - string capability names with optional parameters
- VM has `rootCapabilities` and `capabilityStack: seq[CapabilityScope]`
- Opcodes `OpCapEnter/OpCapExit` push/pop capability scopes
- `OpCapAssert` checks capability before privileged operation
- `VmQuotaConfig` tracks: CPU steps, heap object count, wall clock ms, tool call count
- `checkQuota(vm)` called per instruction in hot loop
- `grantCapability/revokeCapability` API for VM consumers

**What gene-old does:** No capability or quota system. Any Gene code can call any native function. The genex AI extension calls external APIs with no sandboxing.

**Why it matters:** Required for safely executing untrusted Gene code in AI agent contexts. Also needed for the LLM extension to bound resource usage.

**How to apply:**
1. Add `CapabilityScope` type and `quota_config` to `VirtualMachine`
2. Add `IkCapEnter/IkCapExit/IkCapAssert/IkQuotaCheck` to `InstructionKind`
3. Add capability requirements to native function registration
4. Emit capability assertions in compiler for known dangerous operations (file I/O, network, exec)
5. Add `grantCapability/revokeCapability` to the App initialization path

Estimated 4-6 weeks including testing.

---

### 7. Deterministic Replay (MEDIUM impact, MEDIUM effort)

**What gene does:** VM tracks `replayLog: seq[ReplayEvent]`, `replayMode: bool`, `replayCursor: int`. Three instruction kinds: `OpDetSeed` (seed RNG), `OpDetRand` (deterministic random), `OpDetNow` (deterministic time). In replay mode, these return logged values rather than actual random/time values. Also includes `deterministic: bool` flag and `rngState: uint64` for Xorshift64 RNG.

**What gene-old does:** No determinism infrastructure. Random and time functions are non-deterministic.

**Why it matters:** Enables reproducible execution for AI agent testing and debugging. A sequence of tool calls can be replayed with the same random/time values to reproduce bugs.

**How to apply:** Add `rng_state: uint64`, `deterministic: bool`, `replay_log`, and `replay_cursor` to `VirtualMachine`. Add `IkDetSeed/IkDetRand/IkDetNow` instructions. Register `$rand` and `$now` as builtins that check the deterministic flag. Lower effort if capability system is in place first.

---

## What gene-old Does Better (Do Not Change)

These areas are better in gene-old than gene and should be preserved:

1. **AOP system** - gene-old has `Aspect`, `Interception`, before/after/around/invariant advices. gene has nothing comparable. This is a unique differentiator.

2. **GIR bytecode cache** - gene-old's `gir.nim` serializes compiled bytecode to disk keyed by source file. Speeds up repeated runs significantly. gene has no equivalent cache.

3. **computedGoto dispatch** - gene-old's VM uses `{.computedGoto.}` in the hot dispatch loop, which translates to a hardware jump table. gene uses a plain `case` statement. gene-old's approach is measurably faster.

4. **Fixed 256-element stack array** - gene-old's `stack: array[256, Value]` avoids heap allocation for frame stacks. gene uses `stack: seq[Value]` which allocates on heap. For the common case (functions with fewer than 256 temporaries), gene-old is faster.

5. **Rich class system** - gene-old has `Method`, `BoundMethod`, `Mixin`, macro constructors, `prop_types`, property type descriptors. gene's `ClassObj` is significantly simpler.

6. **Richer ValueKind surface** - gene-old's ~100 `ValueKind` variants allow direct type dispatch without a heap pointer dereference. gene uses `VkPointer + HeapKind` for all heap types, requiring an additional dereference to distinguish strings from arrays.

7. **Source trace infrastructure** - gene-old tracks `SourceTrace` through compilation linking instructions to source locations. This is more detailed than gene's `AirSourceSpan`.

8. **Native compilation tier** - gene-old has `native_tier: NativeCompileTier` and `native_entry: pointer` on `Function`, enabling a JIT dispatch pathway. gene does not have this.

---

## Implementation Considerations

| Improvement | Effort | Risk | Dependencies | Recommended Order |
|------------|--------|------|--------------|-------------------|
| Structured diagnostics | 1 week | LOW - additive only | None | 1st |
| Stable extension ABI | 2 weeks | MEDIUM - removes static imports | Must audit genex/ | 2nd |
| Bytecode verifier | 2 weeks | LOW - additive, CI-only | Instruction set stability | 3rd |
| Explicit upvalue capture | 2-3 weeks | MEDIUM - touches closure semantics | Compiler + type_defs | 4th |
| Flat locals optimization | 2-3 weeks | MEDIUM - new instruction kinds | Compiler + VM + GIR | 5th |
| Capability / quota system | 4-6 weeks | MEDIUM - new VM state + opcodes | Compiler + native registration | 6th |
| Deterministic replay | 3 weeks | LOW - additive state in VM | Capability system recommended first | 7th |
| Fixed-width instructions | 6+ weeks | HIGH - requires GIR format bump | All other changes first | Defer |
| WASM target | 8+ weeks | HIGH - platform ifdefs throughout | Stable ABI first | Not recommended short-term |

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Nim `unittest` + shell integration tests |
| Config file | `gene.nimble` (nimble test), `testsuite/run_tests.sh` |
| Quick run command | `nim c -r tests/test_vm.nim` (from gene-old root) |
| Full suite command | `nimble test` |

### Verification Approach per Improvement

- **Structured diagnostics:** `nim c -r tests/test_exception.nim` still passes. New test asserts error output contains `code` and `message` JSON fields.
- **Extension ABI:** Extension tests pass. `nimble buildext` and verify `.dylib` files load. Remove static imports one at a time.
- **Bytecode verifier:** New test emits deliberately bad bytecode and verifies verifier catches it. Normal compilation passes verification.
- **Flat locals:** `nim c -r tests/test_vm.nim` and `testsuite/run_tests.sh` pass. Benchmark fib(24) before/after.
- **Capability system:** New test grants capability, executes privileged code, verifies code without capability throws structured error.

---

## Open Questions

1. **Instruction set migration path**
   - What we know: gene uses fixed-width `AirInst`, gene-old uses `Value`-operand `Instruction`.
   - What's unclear: Can flat locals and upvalue improvements be applied without changing the instruction encoding?
   - Recommendation: Yes - implement flat locals as new `IkLocalLoad/IkLocalStore` instructions added to the existing `InstructionKind` enum. The encoding format does not need to change for improvements 1-6.

2. **GIR format versioning**
   - What we know: Adding new instruction kinds will break existing GIR files.
   - What's unclear: How widely are GIR files deployed? Are there compatibility requirements?
   - Recommendation: Increment the GIR version constant when any new instruction is added. The existing GIR loader should detect version mismatch and fall back to recompile.

3. **Extension ABI stability across Nim versions**
   - What we know: gene's `AirNativeFn` uses C calling convention (`{.cdecl.}`), making it Nim-version independent.
   - What's unclear: Does gene-old's current `NativeFn` type use cdecl?
   - Recommendation: Verify with `grep -n "cdecl\|nimcall" src/gene/types/type_defs.nim`. If not cdecl, the ABI change is necessary.

---

## Sources

### Primary (HIGH confidence)
- Direct code reading: `/Users/gcao/gene-workspace/gene-old/src/gene/vm.nim` and all included sub-files
- Direct code reading: `/Users/gcao/gene-workspace/gene/src/vm/core.nim`, `functions.nim`, `capabilities.nim`, `concurrency.nim`, `control_flow.nim`
- `/Users/gcao/gene-workspace/gene-old/src/gene/types/type_defs.nim` - gene-old type model (1100+ lines)
- `/Users/gcao/gene-workspace/gene/src/types.nim` - gene type model
- `/Users/gcao/gene-workspace/gene/src/ir.nim` - AIR instruction set (147+ instructions)
- `/Users/gcao/gene-workspace/gene/src/air_verify.nim` - bytecode verifier
- `/Users/gcao/gene-workspace/gene/src/native_abi.nim` - extension ABI
- `/Users/gcao/gene-workspace/gene/src/compiler.nim` - gene compiler (2171 lines)
- `/Users/gcao/gene-workspace/gene-old/src/gene/compiler.nim` - gene-old compiler (653 lines)
- `/Users/gcao/gene-workspace/gene-old/.planning/codebase/CONCERNS.md` - documented known issues
- `/Users/gcao/gene-workspace/gene-old/docs/performance.md` - benchmark numbers (~3.76M calls/sec)

### Secondary (MEDIUM confidence)
- CLAUDE.md files from both repos - architectural summaries written by project maintainers
- `/Users/gcao/gene-workspace/gene-old/.planning/codebase/ARCHITECTURE.md` - architecture map

---

## Metadata

**Confidence breakdown:**
- Comparison matrix: HIGH - based on direct source code reading of both implementations
- Improvement prioritization: MEDIUM - effort estimates are approximations; actual effort depends on test coverage and scope of AOP interactions
- Performance claims: MEDIUM - based on gene-old's own `docs/performance.md` benchmarks; gene has no published equivalent benchmark numbers for comparison

**Research date:** 2026-02-27
**Valid until:** 2026-03-27 (30 days; both repos are actively developed on the ai-first branch)
