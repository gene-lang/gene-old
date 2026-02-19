# Gene AIR: AI-Native Intermediate Representation (v0.1 Design)

Status: Draft design for implementation in Nim
Target: Replace/augment current GIR with an AI-native IR while preserving Gene language semantics
Audience: Gene compiler/VM maintainers, tooling engineers, AI agent runtime contributors

## 1. Context and Problem

Current Gene IR (GIR) is a stack bytecode with ~120 instruction kinds, 16-byte instructions, and NaN-tagged runtime values. It works for language execution but does not explicitly model:

- Effects/capabilities for sandboxing
- Deterministic replay
- Checkpoint/resume of full VM state
- Structured concurrency and cancellation trees
- Tool calling as a first-class runtime operation
- Machine-readable diagnostics for automated repair loops

These are required for AI-native execution.

## 2. Scope and Goals

This design defines a new IR called **AIR** (AI-native IR) with:

1. Full support for existing Gene semantics:
   - FP (closures, higher-order functions, pattern matching)
   - OOP (classes/inheritance/constructors/methods/properties/self/super)
   - async/await + futures
   - generators + resume
   - AOP decorators/interception
   - selectors + nil-safe chains
   - pseudo macros + caller_eval
   - literals (array/map/gene)
   - module/namespace import/export
   - try/catch/finally
   - threads
   - enums/ranges/is/typeof
2. AI-native runtime behavior:
   - capability/effect annotations
   - checkpoint/resume
   - tool call ops with schema/retry/idempotency
   - resource sandboxing
   - structured concurrency
   - observability/audit trace
   - deterministic mode (seeded RNG, virtual clock, replay)
   - machine-readable diagnostics
3. Incremental migration from existing Nim codebase.

## 3. Non-Goals

- Not replacing parser or AST format in v0.1
- Not requiring immediate removal of GIR
- Not forcing a JIT redesign in v0.1
- Not requiring static typing for all Gene code

## 4. High-Level Architecture

Pipeline (target):

`Source -> Parser -> AST -> AIR Builder -> AIR Optimizer/Verifier -> AIR Binary -> AIR VM`

Incremental compatibility path:

`Source -> Parser -> AST -> AIR Builder -> AIR->GIR Lowering -> Existing VM`

This allows staged migration while keeping behavior parity.

## 5. AIR Program Model

AIR is function/block-centric with explicit metadata and side tables.

### 5.1 Program Unit

Each AIR module contains:

- Header
- String pool
- Symbol pool
- Constant pool
- Type descriptor pool
- Effect/capability pool
- Tool schema pool
- Function table
- Code section (instructions)
- Debug/trace map
- Optional deterministic replay metadata

### 5.2 Function Object

Each function record has:

- `fn_id`
- flags: async, generator, macro_like, method, decorator, has_try, etc.
- arity + matcher metadata refs
- local slot count
- upvalue count
- entry block PC
- capability requirement set id
- effect summary id
- debug span id

### 5.3 Basic Block

AIR keeps explicit block boundaries and branch targets (for verification and diagnostics). Execution remains stack/slot-friendly for Nim implementation.

## 6. Instruction Encoding and Binary Format

## 6.1 Instruction Word (16 bytes)

To stay close to current memory behavior and simplify migration:

```c
struct AirInst {
  uint16 op;      // opcode
  uint8  mode;    // operand mode + flags
  uint8  a;       // small operand (slot, arg count, flag bits)
  uint32 b;       // operand index/immediate
  uint32 c;       // operand index/immediate
  uint32 d;       // operand index/immediate or trace/effect id
};
```

Operand interpretation is opcode-specific but standardized by `mode`.

### 6.2 Operand Classes

- `K`: constant index
- `S`: symbol index
- `L`: local slot index
- `U`: upvalue index
- `B`: block label/index
- `F`: function index
- `T`: type descriptor index
- `E`: effect/capability profile index
- `M`: method table slot/index
- `TS`: tool schema index
- `Q`: quota profile index

### 6.3 AIR Binary Container

Header (fixed, little-endian):

- magic: `"GAIR"`
- version: `u16` (starts at 1)
- flags: deterministic-compatible, has-debug, has-replay, signed, etc.
- target ABI: value ABI, pointer width policy, endianness
- section count + section directory

Sections (by id):

1. `STRS` string pool
2. `SYMS` symbol table
3. `CNST` constants
4. `TYPE` type descriptors
5. `EFFT` effect + capability descriptors
6. `TOOL` tool schemas
7. `FUNC` function table
8. `CODE` instruction stream
9. `BMAP` block map
10. `DBUG` source spans + trace IDs
11. `OBSV` optional observability dictionary
12. `REPL` optional deterministic replay seed/config
13. `EXTN` extension sections (forward-compatible)

Unknown sections are skipped by length.

## 7. Opcode Set (By Category)

Design principle: keep core compact; AI-native features are thin opcodes + side tables.

Opcode ranges (proposed):

- `0x00-0x1F` core stack/slot/value
- `0x20-0x3F` control flow/exception
- `0x40-0x5F` function/call/closure/generator
- `0x60-0x7F` object/module/selector/construction
- `0x80-0x8F` async/thread/structured concurrency
- `0x90-0x9F` capabilities/sandbox/checkpoint
- `0xA0-0xAF` tool calling
- `0xB0-0xBF` determinism/observability/diagnostics

### 7.1 Core Value/Stack/Slot

- `NOP`
- `CONST K`
- `CONST_NIL`, `CONST_TRUE`, `CONST_FALSE`
- `POP`, `DUP`, `SWAP`, `OVER`
- `LOAD_LOCAL L`, `STORE_LOCAL L`
- `LOAD_UPVALUE U`, `STORE_UPVALUE U`
- `LOAD_SELF`, `LOAD_SUPER`
- `TYPEOF`, `IS_TYPE T`
- `RANGE_NEW`, `ENUM_NEW`, `ENUM_ADD`

### 7.2 Arithmetic/Logic

- `ADD`, `SUB`, `MUL`, `DIV`, `MOD`, `POW`, `NEG`
- `CMP_EQ`, `CMP_NE`, `CMP_LT`, `CMP_LE`, `CMP_GT`, `CMP_GE`
- `LOG_AND`, `LOG_OR`, `LOG_NOT`

### 7.3 Control Flow and Exceptions

- `JUMP B`
- `BR_TRUE B`, `BR_FALSE B`
- `RETURN`
- `THROW`
- `TRY_BEGIN handler_id`
- `TRY_END`
- `CATCH_BEGIN type_or_any`
- `CATCH_END`
- `FINALLY_BEGIN`
- `FINALLY_END`
- `RETHROW`

### 7.4 Functions, Closures, Calls

- `FN_NEW F`
- `CLOSURE_NEW F upvalue_bitmap`
- `CALL argc`
- `CALL_KW argc kw_count`
- `CALL_DYNAMIC`
- `TAIL_CALL argc`
- `CALL_METHOD S argc`
- `CALL_METHOD_KW S argc kw_count`
- `CALL_SUPER S argc`
- `CALL_SUPER_KW S argc kw_count`
- `CALL_MACRO argc` (unevaluated args)
- `CALLER_EVAL`
- `YIELD`
- `RESUME`

### 7.5 Construction Ops

- `ARR_NEW`, `ARR_PUSH`, `ARR_SPREAD`, `ARR_END`
- `MAP_NEW`, `MAP_SET S`, `MAP_SET_DYNAMIC`, `MAP_SPREAD`, `MAP_END`
- `GENE_NEW`, `GENE_SET_TYPE`, `GENE_SET_PROP S`, `GENE_SET_PROP_DYNAMIC`, `GENE_ADD_CHILD`, `GENE_ADD_SPREAD`, `GENE_END`

### 7.6 OOP/AOP/Modules/Selectors

- `CLASS_NEW S`
- `CLASS_EXTENDS`
- `METHOD_DEF S F`
- `CTOR_DEF F`
- `PROP_DEF S T`
- `DECORATOR_APPLY count`
- `INTERCEPT_ENTER`
- `INTERCEPT_EXIT`
- `IMPORT symbol_or_module`
- `EXPORT S`
- `NS_ENTER S`
- `NS_EXIT`
- `GET_MEMBER S`
- `GET_MEMBER_NIL S`
- `GET_MEMBER_DEFAULT S`
- `GET_MEMBER_DYNAMIC`
- `SET_MEMBER S`
- `SET_MEMBER_DYNAMIC`
- `GET_CHILD idx`
- `GET_CHILD_DYNAMIC`

### 7.7 Async, Generators, Threads, Structured Concurrency

- `ASYNC_BEGIN`
- `ASYNC_END`
- `AWAIT`
- `FUTURE_WRAP`
- `THREAD_SPAWN F`
- `TASK_SCOPE_ENTER` (new supervisor scope)
- `TASK_SPAWN F` (child task linked to supervisor)
- `TASK_JOIN`
- `TASK_CANCEL`
- `TASK_DEADLINE`

### 7.8 Capabilities, Sandbox, Checkpoint

- `CAP_ENTER E` (narrow capability set)
- `CAP_EXIT`
- `CAP_ASSERT cap_id`
- `QUOTA_SET Q`
- `QUOTA_CHECK quota_kind amount`
- `CHECKPOINT_HINT`
- `STATE_SAVE checkpoint_slot`
- `STATE_RESTORE checkpoint_slot` (internal/testing/admin only)

### 7.9 Tool Calling

- `TOOL_PREP TS` (bind schema and policy)
- `TOOL_CALL` (args on stack; emits invocation record)
- `TOOL_AWAIT`
- `TOOL_RESULT_UNWRAP`
- `TOOL_RETRY policy_id`

### 7.10 Determinism, Observability, Diagnostics

- `DET_SEED seed_ref`
- `DET_RAND`
- `DET_NOW` (virtual clock)
- `TRACE_EMIT event_kind`
- `AUDIT_EMIT event_kind`
- `DIAG_EMIT diag_code`

## 8. Effect and Capability Model

Effects are declared per function and optionally narrowed per block.

Example capability ids:

- `cap.fs.read`, `cap.fs.write`
- `cap.net.outbound`
- `cap.tool.call:<tool-name>`
- `cap.ffi.call`
- `cap.thread.spawn`
- `cap.clock.real`
- `cap.rand.nondet`

Runtime behavior:

1. Every effectful opcode is mapped to a required capability.
2. VM checks active capability context before execution.
3. Deny-by-default: missing capability raises structured diagnostic.
4. Quotas are checked before and after expensive operations.

This makes policy decisions explicit and machine-checkable.

## 9. Mapping Gene Semantics to AIR

### 9.1 FP (closures, higher-order, pattern matching)

- Function definitions -> `FN_NEW`
- Captures -> `CLOSURE_NEW`
- Higher-order calls -> `CALL*`
- Pattern matcher setup stays in function metadata + matcher side table; execution uses existing matcher engine with AIR entry points.

### 9.2 OOP

- Class definitions -> `CLASS_NEW`, `CLASS_EXTENDS`
- Methods/constructors/properties -> `METHOD_DEF`, `CTOR_DEF`, `PROP_DEF`
- `self`/`super` -> `LOAD_SELF`, `LOAD_SUPER`, `CALL_SUPER*`

### 9.3 Async

- Async body -> `ASYNC_BEGIN ... ASYNC_END`
- Await -> `AWAIT`
- Future conversion -> `FUTURE_WRAP`

### 9.4 Generators

- `yield` -> `YIELD`
- resume path -> `RESUME`
- frame suspension metadata stored in generator object

### 9.5 AOP Decorators/Interception

- Decorator expansion -> `DECORATOR_APPLY`
- Around/before/after hooks -> `INTERCEPT_ENTER/EXIT`
- Existing runtime interception model maps directly

### 9.6 Selectors and Nil-safe Navigation

- Dot chain -> sequence of `GET_MEMBER*` ops
- Nil-safe segment -> `GET_MEMBER_NIL`
- Fallback/default segment -> `GET_MEMBER_DEFAULT`

### 9.7 Pseudo Macros

- Unevaluated argument passing -> `CALL_MACRO`
- Caller evaluation -> `CALLER_EVAL`

### 9.8 Easy Construction ([], {}, ())

- Arrays/maps/genes use construction op groups (`ARR_*`, `MAP_*`, `GENE_*`).

### 9.9 Modules/Namespaces

- Import/export -> `IMPORT`, `EXPORT`
- Namespace body execution -> `NS_ENTER`, `NS_EXIT`

### 9.10 Exceptions

- try/catch/finally maps to `TRY_*`, `CATCH_*`, `FINALLY_*` op groups.

### 9.11 Threads

- Thread start -> `THREAD_SPAWN`
- Structured cancellation done via task tree (`TASK_*`) when using supervised mode.

### 9.12 Enums/Ranges/Type checks

- enums/ranges -> `ENUM_*`, `RANGE_NEW`
- runtime type checks -> `TYPEOF`, `IS_TYPE`

## 10. AI-Native Features Without Core Bloat

AIR avoids opcode explosion by using metadata tables:

- capability/effect checks mostly data-driven by `EFFT` section
- tool schemas in `TOOL` section, invoked by a small op family
- observability IDs in `DBUG/OBSV` side tables
- deterministic replay config in `REPL` section

Core remains compact; advanced behavior is mostly interpreted from table ids.

## 11. VM Architecture (Concrete Nim-Oriented Design)

## 11.1 Execution Engine

Proposed runtime modules:

- `air/types.nim` (IR structs, section reader)
- `air/verify.nim` (control-flow, stack-depth, capability checks)
- `air/vm.nim` (dispatch loop)
- `air/scheduler.nim` (tasks, futures, cancellation)
- `air/checkpoint.nim` (snapshot/restore)
- `air/tooling.nim` (tool calls)

Dispatch loop (direct-threaded if available, `case` fallback):

```nim
while true:
  let inst = code[ip]
  if traceEnabled: traceHook(vm, frame, ip, inst)
  case inst.op
  of OpConst: ...
  of OpCall: ...
  of OpAwait: ...
  ...
```

Verifier runs before execution (or at load time) to guarantee:

- valid block targets
- stack effects balanced per block
- no capability-unsafe op in unprivileged context
- generator/async structural constraints

## 11.2 Frame Management

Proposed frame object:

```nim
type AirFrame = object
  fnId: uint32
  ip: uint32
  base: uint32         # base index into operand stack
  stackTop: uint32
  localsCount: uint16
  upvalueBase: uint32
  caller: int32        # index in frame stack, -1 root
  handlerTop: uint32   # exception handler stack high-water mark
  taskId: uint32
  selfVal: Value
  moduleNs: Namespace
  flags: set[FrameFlag]
```

Differences from current fixed 256-value frame stack:

- one shared operand stack for better large call handling
- frame stores base/stackTop windows
- eliminates hard per-frame fixed array limit

## 11.3 Stack Design

Two stacks:

1. **Operand stack** (`seq[Value]` or chunked arena)
2. **Call frame stack** (`seq[AirFrame]`)

Optional side stacks:

- exception handler stack
- call-base stack for dynamic arity calls
- collection construction base stack

Frame window layout on operand stack:

`[locals...][temps...][call scratch...]`

`LOAD_LOCAL/STORE_LOCAL` use `base + localIndex`.

Benefits:

- keeps stack semantics close to current VM
- easier checkpoint serialization
- better introspection for diagnostics

## 12. Value Representation and Memory Model

## 12.1 Value Representation

Recommended for v0.1: **keep NaN-boxing** for runtime compatibility/perf, with stricter object handle policy.

- 64-bit `Value` remains primary runtime type
- immediate values: nil/bool/small int/char/float
- heap refs: tagged payload pointers (current model)

Add debug/runtime option:

- `--value-model=tagged-union` for sanitizer/debug builds (slower, safer diagnostics)

This dual mode supports fast production and safer debugging without breaking existing code.

## 12.2 GC Strategy

Current runtime uses retain/release patterns plus pooled allocations. AIR recommends explicit progression to:

1. v0.1: keep current ref-count semantics
2. v0.2: add cycle detector for closures/interception graphs
3. v0.3: optional generational tracing mode for high-throughput agents - deferred

Checkpoint requirement:

- all heap objects used by VM frames/tasks must have stable serialization IDs
- serializer must preserve graph shape and shared references

## 13. Checkpoint/Resume Design

Checkpoint includes:

- module hash + AIR hash
- deterministic seed and virtual clock
- frame stack + operand stack windows
- task tree (including cancellation tokens/deadlines)
- pending futures/tool invocations
- heap object graph reachable from VM roots
- quota counters + capability context

Safe-point strategy:

- implicit safe points at `AWAIT`, `TOOL_CALL`, task scheduling boundaries
- explicit safe point via `CHECKPOINT_HINT`

Resume validates code hash and section ABI compatibility before rehydration.

## 14. Deterministic Mode and Replay

Deterministic mode (`--deterministic`) rules:

- RNG only via `DET_RAND` with seeded PRNG
- time only via `DET_NOW` (virtual clock)
- external effects must go through capability-guarded ops with replay records
- thread/task scheduling uses deterministic queue policy

Replay log stores ordered effect records:

- capability checks
- tool requests/responses
- external I/O results
- scheduling decisions (if non-trivial)

## 15. Sandboxing and Quotas

Policy object attached to VM/task:

```nim
type AirPolicy = object
  caps: HashSet[CapId]
  cpuBudgetMs: int64
  memoryBudgetBytes: int64
  toolCallBudget: int32
  netAllowlist: seq[string]
  fsAllowPrefixes: seq[string]
```

Runtime enforcement points:

- before effectful op
- on allocation growth
- per dispatch quantum
- at task spawn/tool call

Violations emit structured diagnostics and optionally kill only the child task (not whole VM).

## 16. Tool Calling ABI

Tool call is first-class with schema and idempotency.

Tool schema table entry:

- `schema_id`
- `name`
- request schema ref
- response schema ref
- timeout default
- retry policy default
- required capability

Invocation record:

- `tool_name`
- serialized args
- idempotency key
- retry policy
- attempt count
- correlation id

Execution flow:

1. `TOOL_PREP schema_id`
2. `TOOL_CALL` -> returns future handle
3. `TOOL_AWAIT`
4. `TOOL_RESULT_UNWRAP` -> value or structured tool error

## 17. FFI Design (C/Nim)

## 17.1 C ABI

```c
typedef uint64_t AirValue;

typedef struct {
  void* vm;
  uint64_t task_id;
  uint64_t caps_mask;
  uint64_t trace_id;
} AirNativeCtx;

typedef enum {
  AIR_NATIVE_OK = 0,
  AIR_NATIVE_ERR = 1,
  AIR_NATIVE_TRAP = 2
} AirNativeStatus;

typedef AirNativeStatus (*AirNativeFn)(
  AirNativeCtx* ctx,
  const AirValue* args,
  uint16_t argc,
  AirValue* out_result,
  AirValue* out_error
);
```

Nim registration API:

```nim
proc register_native_fn*(
  name: string,
  sig: NativeSignature,
  caps: set[CapId],
  fn: NativeFn
)
```

## 17.2 Memory Safety Across Boundary

Rules:

- Native side receives borrowed `AirValue`s unless explicitly duplicated
- Returning heap refs transfers one retain to VM
- Native code cannot retain raw VM pointers across suspension points unless pinned handles are used
- In deterministic mode, FFI calls require replay hooks or are rejected unless marked pure+deterministic

## 17.3 Native Function Dispatch

Dispatch path:

1. Resolve function symbol -> native descriptor
2. Validate arity and type constraints
3. Capability check (`cap.ffi.call` + function-specific caps)
4. Marshal `Value[]`
5. Invoke native function pointer
6. Normalize result or error into `Value`

Inline cache can memoize descriptor per call site.

## 17.4 Native Method Resolution and Invocation

Method resolution order:

1. receiver runtime type id
2. class method table
3. parent chain (MRO linearization)
4. method_missing fallback (if enabled)

Native method call path:

- `CALL_METHOD*` resolves method slot (cached)
- prepends receiver as arg0
- calls native function descriptor
- applies interception/decorator wrappers if present

This remains compatible with current `VkNativeFn` method model while giving explicit cache slots in AIR.

## 18. Structured Concurrency Model

Task tree:

```nim
type TaskNode = ref object
  id: uint32
  parent: uint32
  children: seq[uint32]
  cancelToken: uint64
  deadlineNs: int64
  state: TaskState
  frameTop: int32
```

Semantics:

- `TASK_SCOPE_ENTER` creates supervisor node
- child tasks inherit narrowed caps/quotas
- cancellation propagates parent -> descendants
- failure policy configurable: isolate child / bubble to parent

This unifies async and thread-like tasks under one control plane.

## 19. Observability and Audit

Per-instruction trace fields:

- module id, function id, block id, pc
- trace/span id
- task id
- effect id (if any)

Audit event types:

- instruction
- call enter/exit
- tool call start/result/retry
- capability deny
- quota breach
- checkpoint save/load
- cancellation

Tracing can be sampled or full.

## 20. Machine-Readable Diagnostics

Diagnostic payload format (JSON-like):

```json
{
  "code": "AIR.CAPABILITY.DENIED",
  "severity": "error",
  "stage": "runtime",
  "module": "pkg/foo",
  "function": "fetch-data",
  "pc": 184,
  "span": {"file": "foo.gene", "line": 42, "column": 7},
  "message": "tool.call capability is not granted",
  "expected": {"cap": "cap.tool.call:http.get"},
  "observed": {"active_caps": ["cap.fs.read"]},
  "hints": [
    "Add effect annotation (effects [tool.call:http.get])",
    "Grant capability in policy for this task"
  ],
  "repair_tags": ["capability", "policy", "effect-annotation"]
}
```

Compiler diagnostics use the same envelope with `stage: "compile"`.

## 21. Comparison with Current GIR

| Area | Current GIR | AIR |
|---|---|---|
| Instruction model | Stack bytecode, ~120 ops | Stack/slot bytecode with explicit AI-native op families |
| Effect model | Implicit | Explicit effect/capability metadata + ops |
| Determinism | Best effort | First-class deterministic mode + replay metadata |
| Checkpoint | Not first-class | Full VM/task/state checkpoint protocol |
| Tool calling | Library-level/native | First-class `TOOL_*` ops + schema table |
| Concurrency | async + thread primitives | Structured concurrency supervisor tree |
| Diagnostics | Human-oriented traces | Machine-readable diagnostic envelope |
| Observability | Optional tracing | Standardized trace/audit event model |
| Migration | Existing production path | Incremental lowering to GIR possible |

## 22. Examples: Gene -> AIR

## 22.1 Closure / Higher-Order

Gene:

```gene
(fn make-adder [x]
  (fn [y] (+ x y)))
(var add2 (make-adder 2))
(add2 40)
```

AIR sketch:

```text
FN make_adder:
  LOAD_LOCAL 0           ; x
  CLOSURE_NEW fn_add_inner capture[x]
  RETURN

FN fn_add_inner:
  LOAD_UPVALUE 0         ; x
  LOAD_LOCAL 0           ; y
  ADD
  RETURN

TOP:
  FN_NEW make_adder
  STORE_LOCAL 0
  LOAD_LOCAL 0
  CONST 2
  CALL 1
  STORE_LOCAL 1          ; add2
  LOAD_LOCAL 1
  CONST 40
  CALL 1
  RETURN
```

## 22.2 OOP + Super + Decorator/AOP

Gene:

```gene
(class Animal
  (fn speak [self] "..."))

(class Dog < Animal
  (@trace
   (fn speak [self] (super.speak) " woof")))
```

AIR sketch:

```text
CLASS_NEW "Animal"
METHOD_DEF "speak" fn_animal_speak
CLASS_NEW "Dog"
CLASS_EXTENDS "Animal"
FN_NEW fn_dog_speak
DECORATOR_APPLY 1        ; @trace
METHOD_DEF "speak" fn_dog_speak_wrapped

FN fn_dog_speak:
  LOAD_SELF
  CALL_SUPER "speak" 0
  CONST " woof"
  ADD
  RETURN
```

## 22.3 Async + Tool Call + Checkpoint

Gene:

```gene
(async
  (var r (tool/http.get {:url "https://api.example.com"}))
  (await r))
```

AIR sketch:

```text
ASYNC_BEGIN
  MAP_NEW
  MAP_SET "url" "https://api.example.com"
  TOOL_PREP schema:http.get
  TOOL_CALL
  CHECKPOINT_HINT
  TOOL_AWAIT
ASYNC_END
RETURN
```

## 22.4 Nil-safe Selector Chain

Gene:

```gene
(user?.profile?.email || "n/a")
```

AIR sketch:

```text
LOAD_LOCAL user
GET_MEMBER_NIL "profile"
GET_MEMBER_NIL "email"
BR_TRUE has_email
  POP
  CONST "n/a"
has_email:
RETURN
```

## 23. Incremental Implementation Plan (Nim)

## Phase 1: AIR Data Structures + Serializer

- Add `src/gene/air/types.nim` and `src/gene/air/codec.nim`
- Implement sectioned binary reader/writer
- Add AIR verifier for control flow + stack effects

## Phase 2: Compiler Emission (AIR)

- Build AIR emitter from existing compiler output path
- Reuse matcher/type descriptor structures where possible
- Keep `AIR -> GIR` lowering backend for compatibility

## Phase 3: Runtime Bring-up

- Implement AIR interpreter loop in `src/gene/air/vm.nim`
- Reuse existing runtime value/class/scope structures initially
- Add capability and quota checks around effectful ops

## Phase 4: AI-native Runtime Features

- Task supervisor tree + cancellation
- Tool calling runtime and schema registry
- Checkpoint/save/restore engine
- Deterministic mode + replay logger

## Phase 5: Migration + Optimization

- Run parity tests against existing GIR VM
- Add inline caches for method/native dispatch in AIR VM
- Gradually promote AIR to default execution path

## 24. Compatibility and Risk Notes

- AIR v1 should load side-by-side with GIR; CLI decides backend (`--ir=air|gir`).
- Feature flags gate high-risk behavior (checkpoint, deterministic strictness).
- Existing NaN-box Value ABI remains supported to avoid ecosystem breakage.
- If AIR verifier fails, fallback to GIR path during migration.

## 25. Practical Nim Type Sketch

```nim
type
  AirOpcode* = distinct uint16

  AirInst* = object
    op*: uint16
    mode*: uint8
    a*: uint8
    b*: uint32
    c*: uint32
    d*: uint32

  AirFunction* = object
    nameSym*: uint32
    flags*: uint32
    localCount*: uint16
    upvalueCount*: uint16
    entryPc*: uint32
    effectProfileId*: uint32
    matcherRef*: uint32

  AirModule* = ref object
    header*: AirHeader
    strings*: seq[string]
    symbols*: seq[Key]
    constants*: seq[Value]
    types*: seq[TypeDesc]
    effects*: seq[EffectProfile]
    toolSchemas*: seq[ToolSchema]
    functions*: seq[AirFunction]
    code*: seq[AirInst]
```

This is intentionally close to current `CompilationUnit` patterns.

## 26. Summary

AIR keeps Gene semantics intact while adding AI-native runtime guarantees:

- explicit effects and capabilities
- deterministic and replayable execution
- first-class tool orchestration
- checkpointable long-running agent state
- structured concurrency and cancellation
- machine-readable diagnostics

The design is intentionally incremental, compatible with current Nim VM internals, and practical to implement in phases.

## 27. WASM Compatibility (VM-In-WASM Only)

Scope clarification for this design: **WASM support means running the Gene VM itself inside WASM** (Nim -> WASM).  
This section explicitly does **not** cover compiling AIR/Gene IR into WASM bytecode directly.

### 27.1 Build Targets: Nim VM -> WASM

Use two supported targets with different tradeoffs:

1. **WASI target (`wasm32-wasi`)**
   - Best for server/edge runtimes (Wasmtime, Wasmer, wazero, etc.).
   - Cleaner systems interface than browser JS glue.
   - Recommended for deterministic agent workers.

2. **Emscripten target (`wasm32-unknown-emscripten`)**
   - Best for browser + JS host integration.
   - Easier Promise/event-loop integration from JavaScript.
   - More runtime glue, but broad web compatibility.

#### 27.1.1 Example build profiles (practical templates)

Exact flags vary by Nim/toolchain version; keep these as baseline templates.

WASI profile:

```bash
nim c \
  -d:release \
  --cpu:wasm32 \
  --os:standalone \
  --gc:orc \
  --threads:off \
  --cc:clang \
  --clang.exe:clang \
  --clang.linkerexe:wasm-ld \
  --passC:\"--target=wasm32-wasi --sysroot=$WASI_SYSROOT\" \
  --passL:\"--target=wasm32-wasi --sysroot=$WASI_SYSROOT\" \
  src/gene_main.nim
```

Emscripten profile:

```bash
nim c \
  -d:release \
  --cpu:wasm32 \
  --os:standalone \
  --gc:orc \
  --threads:off \
  --cc:clang \
  --clang.exe:emcc \
  --clang.linkerexe:emcc \
  --passL:\"-s WASM=1 -s MODULARIZE=1 -s EXPORT_ES6=1 -s ALLOW_MEMORY_GROWTH=1\" \
  --passL:\"-s EXPORTED_FUNCTIONS=['_malloc','_free']\" \
  src/gene_main.nim
```

Notes:

- Keep `--threads:off` for baseline portability.
- Add a separate `wasm-threads` build variant only when host supports shared memory + atomics.
- Prefer ORC/ARC-style memory management for predictable ownership at host boundaries.

### 27.2 Async/Event Loop Integration with JS Host

For browser/Emscripten embedding, async must be host-driven:

1. VM exposes cooperative stepping APIs:
   - `vm_step(max_instructions)`
   - `vm_poll()`
   - `vm_resume(task_id, value_or_error)`
2. `AWAIT`, `TOOL_CALL`, timers, and network ops suspend current task and return control to JS host.
3. JS host fulfills pending operations (Promises/fetch/tool adapters), then calls back into `vm_resume`.

Recommended model:

- Treat VM as a deterministic cooperative scheduler, not an OS-threaded runtime.
- Keep each host callback short; process in bounded instruction quanta to avoid UI stalls.
- In deterministic mode, all time/randomness comes from host-provided virtual sources (`DET_NOW`, seeded RNG).

WASI integration follows the same logical contract, but host callbacks are provided by the WASI embedding runtime rather than browser JS.

### 27.3 FFI Mapping to WASM Imports

Inside WASM, direct native C/Nim dynamic FFI is restricted. Use import-based FFI:

1. Define a stable host ABI module (for example `gene_host`):
   - `gene_host_call(op_id, req_ptr, req_len, ctx_id) -> ticket_id`
   - `gene_host_poll(ticket_id) -> status`
   - `gene_host_read(ticket_id, out_ptr, out_cap) -> out_len`
2. Serialize request/response payloads through linear memory (no host pointers in VM state).
3. Map all privileged operations through this ABI:
   - tool calls
   - filesystem/network
   - wall clock/random (if nondeterministic mode is enabled)
   - optional platform services

Safety requirements:

- No raw pointer exchange across boundary.
- Explicit size/ownership contracts for all buffers.
- Capability checks occur before issuing host import calls.

### 27.4 VM Design Constraints for WASM-Safe Operation

To keep the AIR VM WASM-ready, enforce these constraints:

1. **Value ABI discipline**
   - Use `i64/u64` tagged `Value` representation in WASM builds.
   - Do not depend on NaN payload preservation through host/JIT floating-point paths.

2. **No pointer identity persistence**
   - Checkpoints, task state, and replay logs store stable handles/IDs, never raw addresses.

3. **Thread model split**
   - `wasm-single` profile: structured concurrency only, no OS thread spawn.
   - `wasm-threads` profile: enable thread features only with explicit host support.

4. **Dispatch portability**
   - Keep switch/case dispatch path as canonical for WASM.
   - Avoid computed-goto or platform-specific function pointer tricks in WASM builds.

5. **Host boundary purity**
   - Effectful ops must cross host boundary only via import ABI.
   - Native extension loading is disabled in WASM by default.

6. **Determinism controls**
   - Route clock/rand through VM op abstractions (`DET_*`), not direct platform APIs.
   - Capture host-import side effects in replay logs when deterministic replay is enabled.

7. **Memory and stack safety**
   - Use bounded instruction quanta and guard recursion depth.
   - Avoid fixed tiny per-frame stacks; prefer VM-managed dynamic operand/call stacks with explicit limits.
   - Configure linear memory growth policy explicitly for Emscripten/WASI builds.

### 27.5 WASM Readiness Changes to AIR/VM Design

Required concrete changes for this document’s design:

1. Add runtime target profile values: `native`, `wasm-wasi`, `wasm-emscripten`.
2. Add a `wasm-i64-tagged` value-model build mode.
3. Add a host ABI module spec (`air/wasm_host_abi.nim`) and route all effectful runtime calls through it.
4. Add cooperative scheduler entrypoints for embedding (`step/poll/resume`).
5. Gate thread features and native extension loading by target profile + capability policy.
6. Add CI matrix for:
   - native
   - wasm32-wasi
   - wasm32-emscripten (browser harness)

With these constraints, AIR remains unchanged semantically, while the **same Gene VM architecture** can run safely and predictably inside WASM hosts.
