# Phase 02: Actor Runtime - Pattern Map

**Mapped:** 2026-04-20
**Files analyzed:** 20 likely new/modified files
**Analogs found:** 20 / 20 whole-file analogs

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `src/gene/stdlib/actor.nim` | utility | request-response | `src/gene/stdlib/gdat.nim` | role-match |
| `src/gene/stdlib/core.nim` | utility | event-driven | `src/gene/stdlib/core.nim` | exact |
| `src/gene/types/type_defs.nim` | model | request-response | `src/gene/types/type_defs.nim` | exact |
| `src/gene/types/reference_types.nim` | model | request-response | `src/gene/types/reference_types.nim` | exact |
| `src/gene/types/core/native_helpers.nim` | utility | transform | `src/gene/types/core/native_helpers.nim` | exact |
| `src/gene/types/runtime_types.nim` | utility | transform | `src/gene/types/runtime_types.nim` | exact |
| `src/gene/vm/core_helpers.nim` | utility | transform | `src/gene/vm/core_helpers.nim` | exact |
| `src/gene/types/helpers.nim` | utility | event-driven | `src/gene/types/helpers.nim` | exact |
| `src/gene/vm/thread_native.nim` | service | request-response | `src/gene/vm/thread_native.nim` | exact |
| `src/gene/vm/actor.nim` | service | event-driven | `src/gene/vm/thread_native.nim` | partial |
| `src/gene/vm/runtime_helpers.nim` | service | event-driven | `src/gene/vm/runtime_helpers.nim` | exact |
| `src/gene/vm/async.nim` | service | request-response | `src/gene/vm/async.nim` | exact |
| `src/gene/vm/async_exec.nim` | service | event-driven | `src/gene/vm/async_exec.nim` | exact |
| `src/gene/vm.nim` | config | event-driven | `src/gene/vm.nim` | exact |
| `tests/test_extended_types.nim` | test | transform | `tests/test_extended_types.nim` | exact |
| `tests/test_phase2_actor_send_tiers.nim` | test | transform | `tests/test_phase15_freezable_closures.nim` | role-match |
| `tests/integration/test_actor_runtime.nim` | test | event-driven | `tests/integration/test_thread.nim` | role-match |
| `tests/integration/test_actor_reply_futures.nim` | test | request-response | `tests/integration/test_thread.nim` | role-match |
| `tests/integration/test_actor_stop_semantics.nim` | test | event-driven | `tests/integration/test_async.nim` | role-match |
| `testsuite/10-async/actors/*.gene` | test | event-driven | `testsuite/10-async/threads/*.gene` | role-match |

## Pattern Assignments

### `src/gene/stdlib/actor.nim` (utility, request-response)

**Primary analog:** `src/gene/stdlib/gdat.nim`

**Namespace construction pattern** (`src/gene/stdlib/gdat.nim:9-16`, `49-53`):
```nim
proc init_gdat_namespace*() =
  proc gdat_save_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional < 2:
      not_allowed("gdat/save expects value and path")

  let gdat_ns = new_namespace("gdat")
  gdat_ns["save".to_key()] = NativeFn(gdat_save_native).to_value()
  gdat_ns["load".to_key()] = NativeFn(gdat_load_native).to_value()
  App.app.gene_ns.ns["gdat".to_key()] = gdat_ns.to_value()
  App.app.global_ns.ns["gdat".to_key()] = gdat_ns.to_value()
```

**Secondary analog for class exposure:** `src/gene/vm/thread_native.nim:387-400`, `457-466`
```nim
let thread_class_ref = new_ref(VkClass)
thread_class_ref.class = thread_class
App.app.thread_class = thread_class_ref.to_ref_value()

if App.app.gene_ns.kind == VkNamespace:
  let thread_key = "Thread".to_key()
  App.app.gene_ns.ref.ns[thread_key] = App.app.thread_class
```

**Use for Phase 2:** Build `gene/actor` as a namespaced native surface first. Register `enable`, `spawn`, `send`, `send_expect_reply`, and `stop` under a new namespace, then expose `Actor` and `ActorContext` classes through the same application/class-slot pattern the thread runtime uses.

### `src/gene/stdlib/core.nim` (utility, event-driven)

**Analog:** `src/gene/stdlib/core.nim`

**Scheduler loop pattern** (`src/gene/stdlib/core.nim:2433-2475`):
```nim
proc core_run_forever*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  vm.poll_enabled = true
  vm.event_loop_counter = 0
  vm.scheduler_running = true

  while vm.scheduler_running:
    let has_pending_work = vm.pending_futures.len > 0 or
                           vm.pending_pubsub_events.len > 0 or
                           vm.thread_futures.len > 0 or
                           scheduler_callbacks_len() > 0

    try:
      poll(poll_timeout)
    except:
      discard

    do_poll_event_loop(vm)
    call_scheduler_callbacks(vm)
```

**Stdlib wiring pattern** (`src/gene/stdlib/core.nim:4042-4045`, `4122-4126`, `4191-4198`):
```nim
proc init_stdlib_namespaces() =
  stdlib_math.init_math_namespace(App.app.global_ns.ref.ns)
  stdlib_io.init_io_namespace(App.app.global_ns.ref.ns)
  stdlib_system.init_system_namespace(App.app.global_ns.ref.ns)

init_vm_namespace()
init_thread_class()

global_ns["run_forever".to_key()] = core_run_forever.to_value()
global_ns["stop_scheduler".to_key()] = core_stop_scheduler.to_value()
global_ns["keep_alive".to_key()] = keep_alive_fn.to_value()
```

**Use for Phase 2:** Register the actor namespace during stdlib/bootstrap without replacing `run_forever`, `keep_alive`, or thread surfaces. The scheduler loop already treats `thread_futures` as first-class pending work; actor reply futures should plug into the same poll story rather than introducing a second top-level loop.

### `src/gene/types/type_defs.nim` (model, request-response)

**Analog:** `src/gene/types/type_defs.nim`

**ValueKind extension point** (`src/gene/types/type_defs.nim:171-175`):
```nim
# Async types
VkFuture
VkGenerator
VkThread
VkThreadMessage
```

**Application class-slot pattern** (`src/gene/types/type_defs.nim:440-445`):
```nim
future_class*   : Value
generator_class*: Value
thread_class*   : Value
thread_message_class* : Value
thread_message_type_class* : Value
```

**VM tracking fields pattern** (`src/gene/types/type_defs.nim:1115-1130`):
```nim
event_loop_counter*: int
poll_enabled*: bool
pending_futures*: seq[FutureObj]
thread_futures*: Table[int, FutureObj]
message_callbacks*: seq[Value]
thread_local_ns*: Namespace
scheduler_running*: bool
```

**Use for Phase 2:** Add `VkActor` and `VkActorContext` beside existing future/thread kinds, add corresponding `Application` class slots, and add any actor-specific runtime tables here if they are VM-owned. This file is the source of truth for new runtime kinds and per-VM tracking state.

### `src/gene/types/reference_types.nim` (model, request-response)

**Analog:** `src/gene/types/reference_types.nim`

**Reference storage pattern** (`src/gene/types/reference_types.nim:122-133`):
```nim
of VkReference:
  ref_target*: Value
of VkRefTarget:
  target_id*: int64
of VkFuture:
  future*: FutureObj
of VkGenerator:
  generator*: GeneratorObj
of VkThread:
  thread*: Thread
of VkThreadMessage:
  thread_message*: ThreadMessage
```

**Use for Phase 2:** Add actor-handle and actor-context payload storage here rather than inventing a side table. This keeps boxing/unboxing and class lookup aligned with existing runtime reference types.

### `src/gene/types/core/native_helpers.nim` (utility, transform)

**Analog:** `src/gene/types/core/native_helpers.nim`

**Converter pattern** (`src/gene/types/core/native_helpers.nim:7-20`):
```nim
converter to_value*(f: NativeFn): Value {.inline.} =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  result = r.to_ref_value()

converter to_value*(t: type_defs.Thread): Value {.inline.} =
  let r = new_ref(VkThread)
  r.thread = t
  return r.to_ref_value()

converter to_value*(m: type_defs.ThreadMessage): Value {.inline.} =
  let r = new_ref(VkThreadMessage)
  r.thread_message = m
  return r.to_ref_value()
```

**Use for Phase 2:** Add equivalent converters for `Actor` and `ActorContext` so native functions can return handles directly and class methods can stay thin.

### `src/gene/types/runtime_types.nim` (utility, transform)

**Analog:** `src/gene/types/runtime_types.nim`

**Runtime type naming pattern** (`src/gene/types/runtime_types.nim:275-278`):
```nim
of VkFuture: "Future"
of VkGenerator: "Generator"
of VkThread: "Thread"
of VkFunction: "Function"
```

**Use for Phase 2:** Extend the same case table for actor kinds so diagnostics, type strings, and reflective surfaces stay complete.

### `src/gene/vm/core_helpers.nim` (utility, transform)

**Analog:** `src/gene/vm/core_helpers.nim`

**Class resolution pattern** (`src/gene/vm/core_helpers.nim:347-358`):
```nim
of VkFuture:
  safe_class_value(App.app.future_class)
of VkGenerator:
  safe_class_value(App.app.generator_class)
of VkPackage:
  safe_class_value(App.app.package_class)
of VkApplication:
  safe_class_value(App.app.application_class)
of VkThread:
  safe_class_value(THREAD_CLASS_VALUE)
of VkThreadMessage:
  safe_class_value(THREAD_MESSAGE_CLASS_VALUE)
```

**Use for Phase 2:** Add `VkActor` and `VkActorContext` to this switch and cache the resolved class values the same way the thread runtime does.

### `src/gene/types/helpers.nim` (utility, event-driven)

**Analog:** `src/gene/types/helpers.nim`

**VM initialization pattern** (`src/gene/types/helpers.nim:99-109`):
```nim
result[].poll_enabled = false
result[].pending_futures = @[]
result[].pending_pubsub_events = @[]
result[].thread_futures = initTable[int, FutureObj]()
result[].message_callbacks = @[]
```

**Use for Phase 2:** If actor reply tracking, actor ready queues, or actor registries are per-VM rather than global, initialize them here next to existing async/thread containers.

### `src/gene/vm/thread_native.nim` (service, request-response)

**Analog:** `src/gene/vm/thread_native.nim`

**Mailbox substrate pattern** (`src/gene/vm/thread_native.nim:6-16`, `17-25`, `35-46`, `48-73`):
```nim
type
  Channel*[T] = ptr ChannelObj[T]

  ChannelObj*[T] = object
    lock: Lock
    cond: Cond
    data: seq[T]
    capacity: int
    closed: bool

proc send*[T](ch: Channel[T], item: T) =
  acquire(ch.lock)
  while ch.data.len >= ch.capacity and not ch.closed:
    wait(ch.cond, ch.lock)
  if not ch.closed:
    ch.data.add(item)
    signal(ch.cond)
  release(ch.lock)
```

**Worker-slot allocation pattern** (`src/gene/vm/thread_native.nim:110-178`):
```nim
proc init_thread_pool*() =
  initLock(thread_pool_lock)
  next_message_id = 0
  resize_thread_storage(resolve_max_threads())
  THREAD_DATA[0].channel.open(CHANNEL_LIMIT)

proc get_free_thread*(): int =
  acquire(thread_pool_lock)
  defer: release(thread_pool_lock)
  for i in 1..<g_max_threads:
    if not THREADS[i].in_use and THREADS[i].state == TsFree:
      THREADS[i].in_use = true
      THREADS[i].state = TsBusy
      THREADS[i].secret = rand(int.high)
      return i
  return -1
```

**Send + reply future pattern** (`src/gene/vm/thread_native.nim:257-329`):
```nim
proc thread_send_internal(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool, force_reply: bool): Value {.gcsafe.} =
  let thread_id = thread_arg.ref.thread.id
  if not THREADS[thread_id].in_use or THREADS[thread_id].secret != thread_secret:
    raise new_exception(types.Exception, "Thread is no longer valid")

  msg.id = next_message_id
  msg.msg_type = if reply_requested: MtSendExpectReply else: MtSend
  let ser = serialize_literal(message_arg)
  msg.payload_bytes.bytes = string_to_bytes(ser.to_s())
  THREAD_DATA[thread_id].channel.send(msg)

  if reply_requested:
    let future_obj = FutureObj(state: FsPending, value: NIL, success_callbacks: @[], failure_callbacks: @[], nim_future: nil)
    vm.thread_futures[message_id] = future_obj
    vm.poll_enabled = true
```

**Message callback + reply pattern** (`src/gene/vm/thread_native.nim:336-385`, `418-455`):
```nim
proc thread_on_message(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if callback_arg.kind notin {VkFunction, VkNativeFn, VkBlock}:
    raise new_exception(types.Exception, "on_message callback must be a function or block")

proc thread_message_reply(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let ser = serialize_literal(value_arg)
  reply.payload_bytes.bytes = string_to_bytes(ser.to_s())
  THREAD_DATA[msg.from_thread_id].channel.send(reply)
  msg.handled = true
```

**Use for Phase 2:** Copy the blocking queue, slot allocation, validity checks, and reply-future registration patterns. Do not copy serializer-based payload transport into actors; that is the legacy boundary Phase 2 is meant to bypass.

### `src/gene/vm/actor.nim` (service, event-driven)

**Closest analog:** `src/gene/vm/thread_native.nim` with bootstrap help from `src/gene/vm/runtime_helpers.nim`

**What to copy**
- Mailbox implementation from `src/gene/vm/thread_native.nim:6-73`
- Worker-slot bookkeeping from `src/gene/vm/thread_native.nim:110-200`
- Handle validation and reply-future registration from `src/gene/vm/thread_native.nim:257-329`
- Per-thread VM setup from `src/gene/vm/runtime_helpers.nim:64-95`

**What not to copy**
- `serialize_literal` transport from `src/gene/vm/thread_native.nim:293-301`, `437-441`
- Thread public-surface semantics like `Thread.on_message` as the user API

**Use for Phase 2:** If actors move into a sibling runtime module, build it as a scheduler/mailbox layer above the same `Channel[T]`, worker slots, and per-thread VM bootstrap. The current codebase has no exact analog for mutable-spine deep clone or actor stop-state transitions; those must be added on top of the existing substrate.

### `src/gene/vm/runtime_helpers.nim` (service, event-driven)

**Analog:** `src/gene/vm/runtime_helpers.nim`

**Thread-local namespace / context pattern** (`src/gene/vm/runtime_helpers.nim:68-86`):
```nim
proc create_thread_namespace*(thread_id: int): Namespace =
  let thread_ns = new_namespace("thread_local")
  let main_thread_ref = types.Thread(id: 0, secret: THREADS[0].secret)
  thread_ns["$main_thread".to_key()] = main_thread_ref.to_value()
  let current_thread_ref = types.Thread(id: thread_id, secret: THREADS[thread_id].secret)
  thread_ns["$thread".to_key()] = current_thread_ref.to_value()
```

**Per-worker VM setup pattern** (`src/gene/vm/runtime_helpers.nim:88-95`):
```nim
proc setup_thread_vm(thread_id: int) =
  current_thread_id = thread_id
  VM = new_thread_vm()
  ensure_frame_pool()
  VM.thread_local_ns = create_thread_namespace(thread_id)
  gene_namespace_initialized = true
  init_thread_class()
```

**Worker loop pattern** (`src/gene/vm/runtime_helpers.nim:109-128`, `130-188`) :
```nim
proc thread_handler*(thread_id: int) {.thread.} =
  init_vm_for_thread(thread_id)
  while true:
    let msg = THREAD_DATA[thread_id].channel.recv()
    if msg.msg_type == MtTerminate:
      break
    reset_thread_vm_state()
    case msg.msg_type:
    of MtRun, MtRunExpectReply:
      ...
```

**Spawn pattern** (`src/gene/vm/runtime_helpers.nim:251-308`):
```nim
proc spawn_thread(code: Value, return_value: bool): Value =
  let thread_id = get_free_thread()
  init_thread(thread_id, parent_id)
  createThread(THREAD_DATA[thread_id].thread, thread_handler, thread_id)
  THREAD_DATA[thread_id].channel.send(msg)
```

**Use for Phase 2:** Model `ActorContext` injection on `create_thread_namespace` and `setup_thread_vm`, and model the actor scheduler loop on the `thread_handler` structure: blocking receive, VM reset, execute one unit of work, reply/fail, then continue.

### `src/gene/vm/async.nim` (service, request-response)

**Analog:** `src/gene/vm/async.nim`

**Callback scheduling pattern** (`src/gene/vm/async.nim:61-97`):
```nim
proc schedule_future_callbacks(vm: ptr VirtualMachine, future_obj: FutureObj) =
  for pending in vm.pending_futures:
    if pending == future_obj:
      tracked = true
      break
  if not tracked:
    vm.pending_futures.add(future_obj)
  vm.poll_enabled = true

proc execute_future_callbacks*(vm: ptr VirtualMachine, future_obj: FutureObj) {.gcsafe.} =
  if future_obj.state == FsSuccess:
    let callbacks = future_obj.success_callbacks
    future_obj.success_callbacks.setLen(0)
```

**Terminal-state pattern** (`src/gene/vm/async.nim:55-59`, `158-176`, `179-195`):
```nim
proc raise_future_already_terminal(op_name: string, state: FutureState) {.noreturn.} =
  let msg = "GENE.ASYNC.ALREADY_TERMINAL: cannot " & op_name & " a future in state " & future_state_name(state)

if not future_obj.cancel(reason_arg):
  raise_future_already_terminal("cancel", future_obj.state)
execute_future_callbacks(vm, future_obj)
```

**Class registration pattern** (`src/gene/vm/async.nim:294-346`):
```nim
let future_class = new_class("Future")
future_class.def_native_constructor(future_constructor)
future_class.def_native_method("complete", future_complete)
future_class.def_native_method("fail", future_fail)
future_class.def_native_method("cancel", future_cancel)
future_class.def_native_method("on_success", future_on_success)
future_class.def_native_method("on_failure", future_on_failure)
```

**Use for Phase 2:** Actor replies should complete ordinary `FutureObj` instances and use the same terminal-state guardrails. Actor stop should fail or cancel pending reply futures through these existing APIs instead of inventing a separate promise lifecycle.

### `src/gene/vm/async_exec.nim` (service, event-driven)

**Analog:** `src/gene/vm/async_exec.nim`

**Tracking cleanup pattern** (`src/gene/vm/async_exec.nim:110-128`):
```nim
proc detach_future_tracking*(self: ptr VirtualMachine, future_obj: FutureObj) =
  while i < self.pending_futures.len:
    if self.pending_futures[i] == future_obj:
      self.pending_futures.delete(i)
      continue

  for message_id, tracked in self.thread_futures.pairs:
    if tracked == future_obj:
      remove_ids.add(message_id)
```

**Reply polling pattern** (`src/gene/vm/async_exec.nim:129-187`):
```nim
proc poll_event_loop*(self: ptr VirtualMachine) =
  if not self.poll_enabled:
    return

  when not defined(gene_wasm):
    let poll_thread_id = current_thread_id
    if poll_thread_id >= 0 and poll_thread_id < g_max_threads and
       THREADS[poll_thread_id].in_use and THREAD_DATA[poll_thread_id].channel != nil:
      while true:
        let msg_opt = THREAD_DATA[poll_thread_id].channel.try_recv()
        if msg_opt.isNone():
          break
        let msg = msg_opt.get()
        if msg.msg_type == MtReply:
          ...
          discard future_obj.complete(payload)
          self.execute_future_callbacks(future_obj)
```

**Use for Phase 2:** Keep actor reply futures visible to the same poll loop. If actor replies use their own envelope type, follow this exact pattern: non-blocking drain, decode/fail/complete, execute callbacks inline, then delete tracking entries.

### `src/gene/vm.nim` (config, event-driven)

**Analog:** `src/gene/vm.nim`

**Import/include wiring pattern** (`src/gene/vm.nim:96-121`):
```nim
include "./vm/native"

import ./vm/async
include ./vm/async_exec

include ./vm/runtime_helpers

set_vm_exec_callable_hook(exec_callable)
set_vm_exec_callable_with_self_hook(exec_callable_with_self)
set_vm_poll_event_loop_hook(poll_event_loop)

include "./stdlib"
```

**Use for Phase 2:** Wire any new actor module here in the same layer as async/thread/runtime helpers so the hooks and bootstrap order stay coherent.

### `tests/test_extended_types.nim` (test, transform)

**Analog:** `tests/test_extended_types.nim`

**Enum completeness pattern** (`tests/test_extended_types.nim:7-13`):
```nim
test "ValueKind enum completeness":
  check VkRatio.ord > VkInt.ord
  check VkRegex.ord > VkComplexSymbol.ord
  check VkDate.ord > VkTimezone.ord - 4
  check VkThread.ord >= VkFuture.ord
  check VkException.ord == 128
```

**Use for Phase 2:** Extend this with `VkActor` and `VkActorContext` so new runtime kinds are covered by the same baseline completeness test.

### `tests/test_phase2_actor_send_tiers.nim` (test, transform)

**Primary analog:** `tests/test_phase15_freezable_closures.nim`

**Frozen/shared assertion pattern** (`tests/test_phase15_freezable_closures.nim:68-72`, `100-149`):
```nim
proc expect_frozen_flag(v: Value) =
  if isManaged(v):
    check (flags_of(v) and DeepFrozenBit) != 0
    check (flags_of(v) and SharedBit) != 0
  check deep_frozen(v)
```

**Secondary analog:** `tests/test_thread_msg.nim:9-32`
```nim
test "literal payload roundtrips through serialize/deserialize":
  let value = read("{^a [1 2 3] ^b \"ok\"}")
  let ser = serialize_literal(value)
  let roundtripped = deserialize_literal(ser.to_s())

test "non-literal payload is rejected":
  expect type_defs.Exception:
    discard serialize_literal(non_literal)
```

**Use for Phase 2:** Build send-tier tests around three cases: primitives by value, frozen/shared graphs by shared pointer semantics, and mutable graphs by clone semantics. Reuse the flag-inspection helpers from Phase 1.5 for the frozen fast path.

### `tests/integration/test_actor_runtime.nim` (test, event-driven)

**Analog:** `tests/integration/test_thread.nim`

**Harness setup pattern** (`tests/integration/test_thread.nim:46-52`):
```nim
suite "Threading Support":
  setup:
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()
```

**End-to-end send/reply pattern** (`tests/integration/test_thread.nim:177-227`):
```nim
test "Thread.send with keep_alive handles message callbacks":
  let code = """
    (do
      (var worker (spawn (do
        (thread .on_message (fn [msg]
          (msg .reply (+ (msg .payload) 1))
        ))
        (keep_alive)
      )))
      (await (send_expect_reply worker 41))
    )
  """
```

**Use for Phase 2:** Keep the same integration harness and compile/exec setup, but swap the Gene snippets to `gene/actor/*` or `Actor` handle usage. This is the closest end-to-end analog for scheduler progress and mailbox dispatch.

### `tests/integration/test_actor_reply_futures.nim` (test, request-response)

**Primary analog:** `tests/integration/test_thread.nim`

**Worker-self-polling reply pattern** (`tests/integration/test_thread.nim:229-257`):
```nim
test "send_expect_reply from worker thread polls its own channel":
  let code = """
    (await
      (spawn_return
        (do
          ...
          (await ^timeout 200 (send_expect_reply worker 41))
        )
      )
    )
  """
```

**Secondary analog:** `tests/integration/test_async.nim:224-277`
```nim
(var f (new gene/Future))
(f .cancel)
(f .state)

(try
  (await ^timeout 10 f)
  NIL
catch *
  (caught = true)
)
```

**Use for Phase 2:** Cover both local and cross-worker actor reply futures, plus timeout, cancellation, and terminal-state behavior. The thread tests supply the reply shape; the async tests supply the future lifecycle assertions.

### `tests/integration/test_actor_stop_semantics.nim` (test, event-driven)

**Closest analogs:** `tests/integration/test_async.nim` and `src/gene/vm/thread_native.nim`

**Future cancellation assertions** (`tests/integration/test_async.nim:224-277`):
```nim
(var f (new gene/Future))
(f .cancel)
(f .state)
...
check instance_props(err)["code".to_key()].str == "GENE.ASYNC.TIMEOUT"
```

**Handle invalidation pattern** (`src/gene/vm/thread_native.nim:280-285`):
```nim
if thread_id < 0 or thread_id >= g_max_threads:
  raise new_exception(types.Exception, "Invalid thread ID")
if not THREADS[thread_id].in_use or THREADS[thread_id].secret != thread_secret:
  raise new_exception(types.Exception, "Thread is no longer valid")
```

**Use for Phase 2:** Stopped actors should combine these two behaviors: invalidate future sends like dead thread handles and fail outstanding reply futures like cancelled/failed futures. There is no direct actor-stop analog yet; this test file will need to compose the two existing patterns.

### `testsuite/10-async/actors/*.gene` (test, event-driven)

**Analog:** `testsuite/10-async/threads/*.gene`

**Gene-level semantic suite pattern** (`testsuite/10-async/threads/1_send_expect_reply.gene:1-14`, `testsuite/10-async/threads/2_keep_alive_reply.gene:1-15`):
```gene
# Expected: {^a 1 ^b 2}

(do
  (var worker
    (spawn
      (do
        (thread .on_message (fn [msg]
          (msg .reply (msg .payload))
        ))
      )
    )
  )
  (println (await (worker .send_expect_reply {^a 1 ^b 2})))
)
```

**Use for Phase 2:** Add actor-specific `.gene` semantics files in the same style as the thread suite: short self-contained scripts with `# Expected:` headers and one visible actor behavior per file.

## Shared Patterns

### Mailbox And Worker Reuse
**Sources:** `src/gene/vm/thread_native.nim:6-73`, `110-200`, `src/gene/vm/runtime_helpers.nim:109-128`

Apply to `src/gene/vm/actor.nim`, `src/gene/vm/runtime_helpers.nim`, and actor integration tests.

```nim
type
  Channel*[T] = ptr ChannelObj[T]

proc send*[T](ch: Channel[T], item: T) =
  while ch.data.len >= ch.capacity and not ch.closed:
    wait(ch.cond, ch.lock)

proc get_free_thread*(): int =
  for i in 1..<g_max_threads:
    if not THREADS[i].in_use and THREADS[i].state == TsFree:
      THREADS[i].in_use = true
      THREADS[i].state = TsBusy
      return i
```

Planner note: reuse the substrate and slot ownership model; do not spin up a second pool.

### Per-Worker VM Bootstrap And Context Injection
**Sources:** `src/gene/vm/runtime_helpers.nim:68-95`

Apply to `ActorContext`, actor worker start-up, and scheduler loop entry.

```nim
let thread_ns = new_namespace("thread_local")
thread_ns["$thread".to_key()] = current_thread_ref.to_value()
VM.thread_local_ns = create_thread_namespace(thread_id)
init_thread_class()
```

Planner note: `ActorContext` should be injected the way `$thread` is injected now: per worker, after VM allocation and before message execution.

### Reply Futures And Terminal-State Rules
**Sources:** `src/gene/types/core/futures.nim:33-53`, `src/gene/vm/async.nim:61-97`, `158-195`, `src/gene/vm/async_exec.nim:129-187`, `src/gene/vm/exec.nim:4373-4488`

Apply to actor `send_expect_reply`, `ctx.reply`, stop-time failure, and timeout behavior.

```nim
proc transition_to*(f: FutureObj, state: FutureState, payload: Value): bool =
  if f.state != FsPending:
    return false
  f.state = state
  f.value = payload

if not future_obj.cancel(reason_arg):
  raise_future_already_terminal("cancel", future_obj.state)

if msg.msg_type == MtReply:
  discard future_obj.complete(payload)
  self.execute_future_callbacks(future_obj)
```

Planner note: actor replies should be ordinary `FutureObj`s stored in a tracking table and completed by the poll loop.

### Frozen/Shared Publication Contract
**Sources:** `src/gene/types/memory.nim:5-13`, `src/gene/types/core/value_ops.nim:228-356`, `src/gene/stdlib/freeze.nim:98-198`, `tests/test_phase15_freezable_closures.nim:100-149`, `docs/handbook/freeze.md:75-112`, `149-155`

Apply to send-tier classification and actor-safe callable payloads.

```nim
proc deep_frozen*(v: Value): bool
proc shared*(v: Value): bool

proc freeze_value*(v: Value): Value =
  validate_for_freeze(v, "/", visited1)
  tag_for_freeze(v, visited2)
```

Planner note: Phase 2 should consume `deep_frozen/shared` exactly as the transport gate. Frozen closures are already the approved actor-safe callable payload story.

### Scheduler Compatibility Boundary
**Sources:** `src/gene/stdlib/core.nim:2433-2475`, `src/gene/vm/extension.nim:95-105`, `149-156`, `src/genex/http.nim:565-568`, `1096-1111`, `src/genex/ai/bindings.nim:980-999`

Apply to any actor scheduler work touching `run_forever`.

```nim
while vm.scheduler_running:
  do_poll_event_loop(vm)
  call_scheduler_callbacks(vm)

register_scheduler_callback(host_scheduler_dispatcher)
```

Planner note: actors can add work to the existing scheduler, but must not break extension callbacks or the current `thread_futures` draining path.

### Compatibility Boundary: Leave Bare `spawn` And Thread Surfaces Alive
**Sources:** `src/gene/compiler/async.nim:48-77`, `src/gene/vm/exec.nim:4491-4499`, `docs/handbook/freeze.md:94-112`

Apply to Phase 2 API design and test planning.

```nim
proc compile_spawn(self: Compiler, gene: ptr Gene) =
  self.emit(Instruction(kind: IkSpawnThread))

of IkSpawnThread:
  let result = spawn_thread(code_val, return_value)
```

Planner note: do not alias bare `spawn` to actors in Phase 2. Keep thread-first syntax as a compatibility lane.

### Unsupported/WASM Mirror Pattern
**Source:** `src/gene/vm/thread.nim:59-97`

Apply if Phase 2 exposes new actor classes on unsupported platforms.

```nim
proc init_thread_class*() =
  let thread_class = new_class("Thread")
  thread_class.def_native_method("send", thread_unsupported)
  ...
  App.app.gene_ns.ref.ns["Thread".to_key()] = App.app.thread_class
```

Planner note: if actors are surfaced on wasm/unsupported targets, mirror the existing thread stub pattern instead of leaving missing classes.

## No Analog Found

No whole-file gaps were found, but two sub-pattern gaps matter for planning:

| File / Sub-area | Role | Data Flow | Reason |
|---|---|---|---|
| `src/gene/vm/actor.nim` mutable-send clone helper | service | transform | No existing helper deep-clones mutable graphs while pointer-sharing frozen/shared subgraphs. Thread transport serializes literals instead. |
| `src/gene/vm/actor.nim` stop-state machine and outstanding-reply rejection | service | event-driven | Existing code has `cleanup_thread`, dead-handle validation, and `Future.cancel/fail`, but no actor lifecycle state machine that rejects late sends and drains/fails queued replies. |

Planner note: use the substrate patterns above, but treat mutable send-tier cloning and stop semantics as genuinely new implementation work.

## Metadata

**Analog search scope:** `src/gene/types`, `src/gene/vm`, `src/gene/stdlib`, `src/genex`, `tests`, `testsuite`, `docs/handbook`

**Files scanned:** 35

**Pattern extraction date:** 2026-04-20
