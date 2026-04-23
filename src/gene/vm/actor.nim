import locks, tables, osproc, os, times
import asyncfutures
import std/exitprocs

import ../types
import ../stdlib/freeze
import ./thread

type
  ActorSendTier* = enum
    AstByValue
    AstSharedFrozen
    AstClonedMutable

  ActorMailboxMessage = ref object
    payload: Value
    reply_requested: bool
    from_message_id: int
    from_thread_id: int
    from_thread_secret: int

  ActorRuntimeRecord = ref object
    actor: Actor
    thread_id: int
    handler: Value
    state: Value
    stopped: bool
    lock: Lock
    cond: Cond
    mailbox: seq[ActorMailboxMessage]
    pending_sends: seq[ActorMailboxMessage]
    mailbox_limit: int
    dispatched: bool

const DEFAULT_ACTOR_MAILBOX_LIMIT* = 10_000

var actor_runtime_lock: Lock
var actor_system_enabled = false
var actor_spawned = false
var actor_next_id = 1
var actor_worker_ids: seq[int] = @[]
var actor_registry = initTable[int, ActorRuntimeRecord]()
var actor_rr_index = 0
var actor_mailbox_limit = DEFAULT_ACTOR_MAILBOX_LIMIT
var actor_cleanup_registered = false

var current_actor_record {.threadvar.}: ActorRuntimeRecord

initLock(actor_runtime_lock)

proc init_actor_class*()
proc actor_worker_handler(thread_id: int) {.thread.}
proc actor_record_from_value(value: Value): ActorRuntimeRecord
proc shutdown_actor_runtime*()

proc actor_runtime_active*(): bool =
  actor_system_enabled

proc actor_thread_namespace(thread_id: int): Namespace =
  discard thread_id
  new_namespace("thread_local")

proc actor_transport_error(payload: Value): ref types.Exception {.noinline.} =
  new_exception(
    types.Exception,
    "Actor messages cannot transport " & $payload.kind &
      "; only primitives, deep-frozen/shared graphs, frozen closures, and mutable ordinary data are allowed"
  )

proc clone_actor_payload(payload: Value, seen: var Table[uint64, Value]): Value {.gcsafe.}

proc prepare_actor_payload_for_send*(payload: Value): tuple[tier: ActorSendTier, value: Value] {.gcsafe.} =
  case payload.kind
  of VkNil, VkBool, VkInt, VkFloat, VkChar, VkSymbol:
    (AstByValue, payload)
  of VkBytes:
    if not isManaged(payload):
      return (AstByValue, payload)
    if payload.deep_frozen and payload.shared:
      return (AstSharedFrozen, payload)

    var cloned: seq[uint8] = @[]
    for i in 0..<bytes_len(payload):
      cloned.add(bytes_at(payload, i))
    (AstClonedMutable, new_bytes_value(cloned))
  of VkString:
    if payload.deep_frozen and payload.shared:
      return (AstSharedFrozen, payload)
    (AstClonedMutable, payload.str.to_value())
  of VkFunction:
    if payload.deep_frozen and payload.shared:
      return (AstSharedFrozen, payload)
    raise actor_transport_error(payload)
  of VkActor:
    if payload.ref.actor == nil:
      raise actor_transport_error(payload)
    (AstByValue, Actor(id: payload.ref.actor.id).to_value())
  of VkArray, VkMap, VkGene:
    if payload.deep_frozen and payload.shared:
      return (AstSharedFrozen, payload)
    var seen = initTable[uint64, Value]()
    (AstClonedMutable, clone_actor_payload(payload, seen))
  else:
    raise actor_transport_error(payload)

proc actor_payload_clone_id(payload: Value): uint64 {.inline.} =
  cast[uint64](payload) and PAYLOAD_MASK

proc clone_actor_payload(payload: Value, seen: var Table[uint64, Value]): Value {.gcsafe.} =
  case payload.kind
  of VkNil, VkBool, VkInt, VkFloat, VkChar, VkSymbol:
    payload
  of VkBytes:
    if not isManaged(payload):
      return payload
    if payload.deep_frozen and payload.shared:
      return payload
    var cloned: seq[uint8] = @[]
    for i in 0..<bytes_len(payload):
      cloned.add(bytes_at(payload, i))
    new_bytes_value(cloned)
  of VkString:
    if payload.deep_frozen and payload.shared:
      return payload
    payload.str.to_value()
  of VkFunction:
    if payload.deep_frozen and payload.shared:
      return payload
    raise actor_transport_error(payload)
  of VkActor:
    if payload.ref.actor == nil:
      raise actor_transport_error(payload)
    Actor(id: payload.ref.actor.id).to_value()
  of VkArray:
    if payload.deep_frozen and payload.shared:
      return payload
    let payload_id = actor_payload_clone_id(payload)
    if seen.hasKey(payload_id):
      return seen[payload_id]
    let cloned = new_array_value()
    seen[payload_id] = cloned
    for item in array_data(payload):
      array_data(cloned).add(clone_actor_payload(item, seen))
    cloned
  of VkMap:
    if payload.deep_frozen and payload.shared:
      return payload
    let payload_id = actor_payload_clone_id(payload)
    if seen.hasKey(payload_id):
      return seen[payload_id]
    let cloned = new_map_value()
    seen[payload_id] = cloned
    for key, value in map_data(payload):
      map_data(cloned)[key] = clone_actor_payload(value, seen)
    cloned
  of VkGene:
    if payload.deep_frozen and payload.shared:
      return payload
    let payload_id = actor_payload_clone_id(payload)
    if seen.hasKey(payload_id):
      return seen[payload_id]
    let cloned =
      if payload.gene.type == NIL:
        new_gene_value()
      else:
        new_gene_value(clone_actor_payload(payload.gene.type, seen))
    seen[payload_id] = cloned
    for key, value in payload.gene.props:
      cloned.gene.props[key] = clone_actor_payload(value, seen)
    for child in payload.gene.children:
      cloned.gene.children.add(clone_actor_payload(child, seen))
    cloned
  else:
    raise actor_transport_error(payload)

proc ensure_actor_frame_pool() =
  if FRAMES.len == 0:
    FRAMES = newSeqOfCap[Frame](INITIAL_FRAME_POOL_SIZE)
    for _ in 0..<INITIAL_FRAME_POOL_SIZE:
      FRAMES.add(cast[Frame](alloc0(sizeof(FrameObj))))
      FRAME_ALLOCS.inc()

proc setup_actor_thread_vm(thread_id: int) =
  current_thread_id = thread_id
  VM = new_vm_ptr()
  ensure_actor_frame_pool()
  VM.thread_local_ns = actor_thread_namespace(thread_id)

proc set_actor_mailbox_limit_for_test*(limit: int) =
  if limit <= 0:
    raise new_exception(types.Exception, "actor mailbox limit must be positive")
  actor_mailbox_limit = limit

proc actor_wake_worker(thread_id, actor_id: int) =
  if thread_id <= 0 or thread_id >= g_max_threads:
    return
  if THREAD_DATA[thread_id].channel == nil:
    return

  var wake: ThreadMessage
  new(wake)
  wake.id = next_thread_message_id()
  wake.msg_type = MtSend
  wake.payload = actor_id.to_value()
  wake.payload_bytes = ThreadPayload(bytes: @[])
  wake.from_thread_id = current_thread_id
  wake.from_thread_secret = THREADS[current_thread_id].secret
  THREAD_DATA[thread_id].channel.send(wake)

proc actor_signal_space(record: ActorRuntimeRecord) =
  while record.mailbox.len < record.mailbox_limit and record.pending_sends.len > 0:
    record.mailbox.add(record.pending_sends[0])
    record.pending_sends.delete(0)
  broadcast(record.cond)

proc actor_enqueue_message(record: ActorRuntimeRecord, msg: ActorMailboxMessage, from_actor: bool) =
  var wake_thread_id = -1
  var wake_actor_id = -1

  acquire(record.lock)
  while not from_actor and record.mailbox.len >= record.mailbox_limit and not record.stopped:
    wait(record.cond, record.lock)

  if record.stopped:
    release(record.lock)
    raise new_exception(types.Exception, "Actor is stopped")

  if from_actor and record.mailbox.len >= record.mailbox_limit:
    if record.pending_sends.len >= record.mailbox_limit:
      release(record.lock)
      raise new_exception(types.Exception, "Actor mailbox is full")
    record.pending_sends.add(msg)
    release(record.lock)
    return

  record.mailbox.add(msg)
  if not record.dispatched:
    record.dispatched = true
    wake_thread_id = record.thread_id
    wake_actor_id = record.actor.id
  release(record.lock)

  if wake_thread_id != -1:
    actor_wake_worker(wake_thread_id, wake_actor_id)

proc actor_enable_workers(worker_count: int) =
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)

  if actor_system_enabled:
    raise new_exception(types.Exception, "gene/actor/enable can only be called once")
  if actor_spawned:
    raise new_exception(types.Exception, "gene/actor/enable must run before actors are spawned")

  let available_workers = max(0, g_max_threads - 1)
  if available_workers == 0:
    raise new_exception(types.Exception, "Actor runtime requires at least one worker thread")
  if worker_count <= 0:
    raise new_exception(types.Exception, "gene/actor/enable requires at least one worker")
  if worker_count > available_workers:
    raise new_exception(types.Exception, "gene/actor/enable exceeds the configured worker pool")

  actor_worker_ids.setLen(0)
  for _ in 0..<worker_count:
    let thread_id = get_free_thread()
    if thread_id == -1:
      raise new_exception(types.Exception, "Actor worker pool exhausted")
    init_thread(thread_id, current_thread_id)
    createThread(THREAD_DATA[thread_id].thread, actor_worker_handler, thread_id)
    actor_worker_ids.add(thread_id)

  if not actor_cleanup_registered:
    actor_cleanup_registered = true
    addExitProc(shutdown_actor_runtime)

  actor_system_enabled = true

proc actor_spawn_value*(handler: Value, state: Value = NIL): Value =
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)

  if not actor_system_enabled:
    raise new_exception(types.Exception, "gene/actor/spawn requires gene/actor/enable first")
  if actor_worker_ids.len == 0:
    raise new_exception(types.Exception, "Actor runtime has no available workers")
  if handler.kind == VkBlock:
    raise new_exception(types.Exception, "gene/actor/spawn does not accept block handlers; use fn")
  if handler.kind notin {VkFunction, VkNativeFn}:
    raise new_exception(types.Exception, "gene/actor/spawn expects a callable handler")
  if handler.kind == VkFunction:
    discard freeze_value(handler)
  let routed_state = prepare_actor_payload_for_send(state)

  let worker_id = actor_worker_ids[actor_rr_index mod actor_worker_ids.len]
  actor_rr_index.inc()

  let actor_handle = Actor(id: actor_next_id)
  actor_next_id.inc()
  let record = ActorRuntimeRecord(
    actor: actor_handle,
    thread_id: worker_id,
    handler: handler,
    state: routed_state.value,
    stopped: false,
    mailbox: @[],
    pending_sends: @[],
    mailbox_limit: actor_mailbox_limit,
    dispatched: false
  )
  initLock(record.lock)
  initCond(record.cond)
  actor_registry[actor_handle.id] = record
  actor_spawned = true
  actor_handle.to_value()

proc actor_pop_message(record: ActorRuntimeRecord): ActorMailboxMessage =
  acquire(record.lock)
  if record.stopped or record.mailbox.len == 0:
    record.dispatched = false
    release(record.lock)
    return nil

  result = record.mailbox[0]
  record.mailbox.delete(0)
  actor_signal_space(record)
  release(record.lock)

proc actor_finish_turn(record: ActorRuntimeRecord) =
  var wake_thread_id = -1
  var wake_actor_id = -1

  acquire(record.lock)
  actor_signal_space(record)
  if record.stopped or record.mailbox.len == 0:
    record.dispatched = false
  else:
    wake_thread_id = record.thread_id
    wake_actor_id = record.actor.id
  release(record.lock)

  if wake_thread_id != -1:
    actor_wake_worker(wake_thread_id, wake_actor_id)

proc stop_actor_record(record: ActorRuntimeRecord): seq[ActorMailboxMessage] =
  acquire(record.lock)
  record.stopped = true
  for msg in record.mailbox:
    if msg.reply_requested:
      result.add(msg)
  for msg in record.pending_sends:
    if msg.reply_requested:
      result.add(msg)
  record.mailbox.setLen(0)
  record.pending_sends.setLen(0)
  record.dispatched = false
  broadcast(record.cond)
  release(record.lock)

proc send_actor_reply(msg: ActorMailboxMessage, payload: Value) {.gcsafe.} =
  if msg.from_thread_id < 0 or msg.from_thread_id >= g_max_threads:
    return
  if THREAD_DATA[msg.from_thread_id].channel == nil:
    return

  var reply: ThreadMessage
  new(reply)
  reply.id = next_thread_message_id()
  reply.msg_type = MtReply
  reply.payload = NIL
  reply.payload_bytes = ThreadPayload(bytes: @[])
  if payload != NIL:
    let routed = prepare_actor_payload_for_send(payload)
    reply.payload = routed.value
  reply.from_message_id = msg.from_message_id
  reply.from_thread_id = current_thread_id
  reply.from_thread_secret = THREADS[current_thread_id].secret
  THREAD_DATA[msg.from_thread_id].channel.send(reply)

proc send_actor_reply_from_context(ctx: ActorContext, payload: Value) {.gcsafe.} =
  if ctx == nil or not ctx.reply_requested:
    raise new_exception(types.Exception, "ActorContext.reply requires send_expect_reply")
  if ctx.reply_sent:
    raise new_exception(types.Exception, "ActorContext.reply can only be called once per message")
  if ctx.reply_thread_id < 0 or ctx.reply_thread_id >= g_max_threads:
    raise new_exception(types.Exception, "ActorContext.reply target thread is invalid")
  if not THREADS[ctx.reply_thread_id].in_use or THREADS[ctx.reply_thread_id].secret != ctx.reply_thread_secret:
    raise new_exception(types.Exception, "ActorContext.reply target thread is no longer valid")

  var reply: ThreadMessage
  new(reply)
  reply.id = next_thread_message_id()
  reply.msg_type = MtReply
  reply.payload = NIL
  reply.payload_bytes = ThreadPayload(bytes: @[])
  if payload != NIL:
    let routed = prepare_actor_payload_for_send(payload)
    reply.payload = routed.value
  reply.from_message_id = ctx.reply_message_id
  reply.from_thread_id = current_thread_id
  reply.from_thread_secret = THREADS[current_thread_id].secret
  THREAD_DATA[ctx.reply_thread_id].channel.send(reply)
  ctx.reply_sent = true

proc send_actor_failure(msg: ActorMailboxMessage, message: string) {.gcsafe.} =
  let error_payload = new_map_value()
  map_data(error_payload)["__thread_error__".to_key()] = true.to_value()
  map_data(error_payload)["message".to_key()] = message.to_value()
  send_actor_reply(msg, error_payload)

proc actor_lookup(actor_id: int): ActorRuntimeRecord =
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)
  actor_registry.getOrDefault(actor_id)

proc actor_process_message(msg: ThreadMessage) =
  if msg.payload.kind != VkInt:
    return

  let actor_id = msg.payload.int64.int
  let record = actor_lookup(actor_id)
  if record == nil:
    return

  let mailbox_msg = actor_pop_message(record)
  if mailbox_msg == nil:
    return

  acquire(record.lock)
  let actor_state = record.state
  let handler = record.handler
  let is_stopped = record.stopped
  release(record.lock)

  if is_stopped:
    if mailbox_msg.reply_requested:
      send_actor_failure(mailbox_msg, "Actor is stopped")
    actor_finish_turn(record)
    return

  current_actor_record = record
  let ctx = ActorContext(
    actor: record.actor,
    reply_requested: mailbox_msg.reply_requested,
    reply_sent: false,
    reply_message_id: mailbox_msg.from_message_id,
    reply_thread_id: mailbox_msg.from_thread_id,
    reply_thread_secret: mailbox_msg.from_thread_secret
  )

  try:
    let next_state =
      case handler.kind
      of VkFunction:
        vm_exec_callable(VM, handler, @[ctx.to_value(), mailbox_msg.payload, actor_state])
      of VkNativeFn:
        call_native_fn(handler.ref.native_fn, VM, @[ctx.to_value(), mailbox_msg.payload, actor_state])
      else:
        raise new_exception(types.Exception, "Actor handler must be callable")

    acquire(record.lock)
    record.state = next_state
    let is_stopped = record.stopped
    release(record.lock)

    if mailbox_msg.reply_requested and not ctx.reply_sent:
      if is_stopped:
        send_actor_failure(mailbox_msg, "Actor is stopped")
      else:
        send_actor_reply(mailbox_msg, NIL)
  except CatchableError as exc:
    if mailbox_msg.reply_requested and not ctx.reply_sent:
      send_actor_failure(mailbox_msg, exc.msg)
  finally:
    current_actor_record = nil
    actor_finish_turn(record)

proc actor_worker_handler(thread_id: int) {.thread.} =
  {.cast(gcsafe).}:
    try:
      setup_actor_thread_vm(thread_id)
      while true:
        let msg = THREAD_DATA[thread_id].channel.recv()
        if msg.msg_type == MtTerminate:
          break

        reset_vm_state()
        case msg.msg_type
        of MtSend, MtSendExpectReply:
          actor_process_message(msg)
        else:
          discard
    finally:
      if VM != nil:
        free_vm_ptr(VM)
        VM = nil
      cleanup_thread(thread_id)

proc actor_record_from_value(value: Value): ActorRuntimeRecord =
  if value.kind != VkActor or value.ref.actor == nil:
    raise new_exception(types.Exception, "actor methods can only be called on an Actor")
  let record = actor_lookup(value.ref.actor.id)
  if record == nil:
    raise new_exception(types.Exception, "Actor is no longer valid")
  record

proc actor_send_value*(vm: ptr VirtualMachine, actor_value: Value, payload: Value,
                       reply_requested = false): Value =
  let record = actor_record_from_value(actor_value)

  acquire(record.lock)
  let is_stopped = record.stopped
  let thread_id = record.thread_id
  release(record.lock)

  if is_stopped:
    raise new_exception(types.Exception, "Actor is stopped")
  if thread_id <= 0 or thread_id >= g_max_threads:
    raise new_exception(types.Exception, "Actor worker is no longer valid")
  if THREAD_DATA[thread_id].channel == nil:
    raise new_exception(types.Exception, "Actor worker is unavailable")

  let routed = prepare_actor_payload_for_send(payload)

  let message_id = next_thread_message_id()
  var future_obj: FutureObj = nil
  let future_val = new_ref(VkFuture)
  if reply_requested:
    let nim_fut = newFuture[Value]("actor_send_expect_reply")
    future_obj = FutureObj(
      state: FsPending,
      value: NIL,
      success_callbacks: @[],
      failure_callbacks: @[],
      nim_future: nim_fut
    )
    vm.thread_futures[message_id] = future_obj
    vm.poll_enabled = true
    future_val.future = future_obj

  let msg = ActorMailboxMessage(
    payload: routed.value,
    reply_requested: reply_requested,
    from_message_id: message_id,
    from_thread_id: current_thread_id,
    from_thread_secret: THREADS[current_thread_id].secret
  )
  try:
    actor_enqueue_message(record, msg, current_actor_record != nil)
  except CatchableError:
    if reply_requested:
      vm.thread_futures.del(message_id)
    raise

  if reply_requested:
    return future_val.to_ref_value()
  NIL

proc actor_send_internal(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                         has_keyword_args: bool, reply_requested: bool): Value =
  if get_method_arg_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "Actor.send requires a message")

  let self_arg = get_self(args, has_keyword_args)
  let payload = get_method_arg(args, 0, has_keyword_args)
  actor_send_value(vm, self_arg, payload, reply_requested)

proc actor_send_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    actor_send_internal(vm, args, arg_count, has_keyword_args, false)

proc actor_send_expect_reply_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                    has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    actor_send_internal(vm, args, arg_count, has_keyword_args, true)

proc actor_send_expect_reply_sync_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                       has_keyword_args: bool): Value =
  if get_method_arg_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "Actor.send_expect_reply_sync requires a message")

  var timeout_ms = 2_000
  if has_keyword_args and has_keyword_arg(args, "timeout"):
    let timeout_arg = get_keyword_arg(args, "timeout")
    case timeout_arg.kind
    of VkInt:
      timeout_ms = max(0, timeout_arg.int64.int)
    of VkFloat:
      timeout_ms = max(0, (timeout_arg.float64 * 1000.0).int)
    else:
      raise new_exception(types.Exception, "Actor.send_expect_reply_sync ^timeout expects int milliseconds or float seconds")

  let future_value = actor_send_value(vm, get_self(args, has_keyword_args), get_method_arg(args, 0, has_keyword_args), true)
  let future_obj = future_value.ref.future
  let deadline = epochTime() + (timeout_ms.float / 1000.0)

  while future_obj.state == FsPending and epochTime() < deadline:
    vm.event_loop_counter = 100
    if vm_poll_event_loop_hook.isNil:
      raise new_exception(types.Exception, "Actor.send_expect_reply_sync requires the VM poll hook")
    vm_poll_event_loop_hook(vm)
    sleep(1)

  case future_obj.state
  of FsSuccess:
    future_obj.value
  of FsFailure:
    let err = future_obj.value
    if err.kind == VkInstance:
      let msg = instance_props(err).getOrDefault("message".to_key(), NIL)
      if msg.kind == VkString:
        raise new_exception(types.Exception, msg.str)
    elif err.kind == VkString:
      raise new_exception(types.Exception, err.str)
    raise new_exception(types.Exception, "Actor.send_expect_reply_sync failed")
  of FsCancelled:
    raise new_exception(types.Exception, "Actor.send_expect_reply_sync cancelled")
  of FsPending:
    raise new_exception(types.Exception, "Actor.send_expect_reply_sync timed out")

proc actor_send_expect_reply_sync_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                         has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    actor_send_expect_reply_sync_impl(vm, args, arg_count, has_keyword_args)

proc actor_enable_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value =
  discard vm
  let available_workers = max(0, g_max_threads - 1)
  var worker_count = min(available_workers, max(1, countProcessors()))
  if has_keyword_args and has_keyword_arg(args, "workers"):
    let workers_arg = get_keyword_arg(args, "workers")
    if workers_arg.kind != VkInt:
      raise new_exception(types.Exception, "gene/actor/enable ^workers expects an integer")
    worker_count = workers_arg.int64.int
  actor_enable_workers(worker_count)
  NIL

proc actor_enable_native*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                          has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    actor_enable_impl(vm, args, arg_count, has_keyword_args)

proc actor_enable_for_test*(workers: int) =
  actor_enable_workers(workers)

proc actor_spawn_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                      has_keyword_args: bool): Value =
  discard vm
  if get_positional_count(arg_count, has_keyword_args) != 1:
    raise new_exception(types.Exception, "gene/actor/spawn expects exactly one handler")

  let handler = get_positional_arg(args, 0, has_keyword_args)
  let state =
    if has_keyword_args and has_keyword_arg(args, "state"): get_keyword_arg(args, "state")
    else: NIL
  actor_spawn_value(handler, state)

proc actor_spawn_native*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                         has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    actor_spawn_impl(vm, args, arg_count, has_keyword_args)

proc actor_stop_impl(args: ptr UncheckedArray[Value], has_keyword_args: bool): Value =
  let record = actor_record_from_value(get_self(args, has_keyword_args))
  let failed = stop_actor_record(record)
  for msg in failed:
    send_actor_failure(msg, "Actor is stopped")
  NIL

proc actor_stop_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  discard arg_count
  {.cast(gcsafe).}:
    actor_stop_impl(args, has_keyword_args)

proc actor_context_actor_impl(args: ptr UncheckedArray[Value], has_keyword_args: bool): Value =
  let self_arg = get_self(args, has_keyword_args)
  if self_arg.kind != VkActorContext or self_arg.ref.actor_context == nil:
    raise new_exception(types.Exception, "actor can only be called on an ActorContext")
  self_arg.ref.actor_context.actor.to_value()

proc actor_context_actor_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  discard arg_count
  {.cast(gcsafe).}:
    actor_context_actor_impl(args, has_keyword_args)

proc actor_reply_for_test*(ctx: Value, value: Value) {.gcsafe.} =
  if ctx.kind != VkActorContext or ctx.ref.actor_context == nil:
    raise new_exception(types.Exception, "actor reply helper requires an ActorContext")
  send_actor_reply_from_context(ctx.ref.actor_context, value)

proc actor_context_reply_impl(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if get_method_arg_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "ActorContext.reply requires a value")
  actor_reply_for_test(get_self(args, has_keyword_args), get_method_arg(args, 0, has_keyword_args))
  NIL

proc actor_context_reply_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  {.cast(gcsafe).}:
    actor_context_reply_impl(args, arg_count, has_keyword_args)

proc actor_context_stop_impl(): Value =
  if current_actor_record != nil:
    let failed = stop_actor_record(current_actor_record)
    for msg in failed:
      send_actor_failure(msg, "Actor is stopped")
  NIL

proc actor_context_stop_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                               has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  discard args
  discard arg_count
  discard has_keyword_args
  {.cast(gcsafe).}:
    actor_context_stop_impl()

proc init_actor_runtime*() =
  shutdown_actor_runtime()
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)
  actor_system_enabled = false
  actor_spawned = false
  actor_next_id = 1
  actor_worker_ids = @[]
  actor_registry = initTable[int, ActorRuntimeRecord]()
  actor_rr_index = 0
  actor_mailbox_limit = DEFAULT_ACTOR_MAILBOX_LIMIT

proc shutdown_actor_runtime*() =
  var worker_ids: seq[int] = @[]

  acquire(actor_runtime_lock)
  worker_ids = actor_worker_ids
  actor_worker_ids = @[]
  actor_registry = initTable[int, ActorRuntimeRecord]()
  actor_system_enabled = false
  actor_spawned = false
  actor_rr_index = 0
  release(actor_runtime_lock)

  for thread_id in worker_ids:
    if thread_id <= 0 or thread_id >= g_max_threads:
      continue
    if THREAD_DATA[thread_id].channel == nil:
      continue

    var term: ThreadMessage
    new(term)
    term.id = next_thread_message_id()
    term.msg_type = MtTerminate
    term.payload = NIL
    term.payload_bytes = ThreadPayload(bytes: @[])
    term.from_thread_id = current_thread_id
    term.from_thread_secret = THREADS[current_thread_id].secret
    THREAD_DATA[thread_id].channel.send(term)
    joinThread(THREAD_DATA[thread_id].thread)
    THREAD_DATA[thread_id].channel = nil

proc init_actor_class*() =
  if not gene_namespace_initialized:
    return
  if App.app.actor_class.kind == VkClass and App.app.actor_context_class.kind == VkClass:
    return

  let actor_class = new_class("Actor")
  if App.app.object_class.kind == VkClass:
    actor_class.parent = App.app.object_class.ref.class
  actor_class.def_native_method("send", actor_send_native)
  actor_class.def_native_method("send_expect_reply", actor_send_expect_reply_native)
  actor_class.def_native_method("send_expect_reply_sync", actor_send_expect_reply_sync_native)
  actor_class.def_native_method("stop", actor_stop_native)

  let actor_class_ref = new_ref(VkClass)
  actor_class_ref.class = actor_class
  App.app.actor_class = actor_class_ref.to_ref_value()

  let actor_context_class = new_class("ActorContext")
  if App.app.object_class.kind == VkClass:
    actor_context_class.parent = App.app.object_class.ref.class
  actor_context_class.def_native_method("actor", actor_context_actor_native)
  actor_context_class.def_native_method("reply", actor_context_reply_native)
  actor_context_class.def_native_method("stop", actor_context_stop_native)

  let actor_context_class_ref = new_ref(VkClass)
  actor_context_class_ref.class = actor_context_class
  App.app.actor_context_class = actor_context_class_ref.to_ref_value()

  if App.app.gene_ns.kind == VkNamespace:
    App.app.gene_ns.ref.ns["Actor".to_key()] = App.app.actor_class
    App.app.gene_ns.ref.ns["ActorContext".to_key()] = App.app.actor_context_class
