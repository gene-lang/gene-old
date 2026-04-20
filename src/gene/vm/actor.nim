import locks, tables, osproc

import ../types
import ../serdes
import ../stdlib/freeze
import ./thread
import ./utils

type
  ActorRuntimeRecord = ref object
    actor: Actor
    thread_id: int
    handler: Value
    state: Value
    stopped: bool
    lock: Lock

var actor_runtime_lock: Lock
var actor_system_enabled = false
var actor_spawned = false
var actor_next_id = 1
var actor_worker_ids: seq[int] = @[]
var actor_registry = initTable[int, ActorRuntimeRecord]()
var actor_rr_index = 0

var current_actor_record {.threadvar.}: ActorRuntimeRecord
var current_actor_message {.threadvar.}: ThreadMessage
var current_actor_reply_sent {.threadvar.}: bool

initLock(actor_runtime_lock)

proc init_actor_class*()

proc actor_thread_namespace(thread_id: int): Namespace =
  let thread_ns = new_namespace("thread_local")

  let main_thread_ref = types.Thread(
    id: 0,
    secret: THREADS[0].secret
  )
  thread_ns["$main_thread".to_key()] = main_thread_ref.to_value()
  thread_ns["main_thread".to_key()] = main_thread_ref.to_value()

  let current_thread_ref = types.Thread(
    id: thread_id,
    secret: THREADS[thread_id].secret
  )
  thread_ns["$thread".to_key()] = current_thread_ref.to_value()
  thread_ns["thread".to_key()] = current_thread_ref.to_value()

  thread_ns

proc actor_envelope_actor_id_key(): Key {.inline.} =
  "__actor_id__".to_key()

proc actor_envelope_payload_key(): Key {.inline.} =
  "payload".to_key()

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

proc send_actor_reply(msg: ThreadMessage, payload: Value) =
  if msg.from_thread_id < 0 or msg.from_thread_id >= g_max_threads:
    return
  if THREAD_DATA[msg.from_thread_id].channel == nil:
    return

  var reply: ThreadMessage
  new(reply)
  reply.id = next_message_id
  reply.msg_type = MtReply
  reply.payload = NIL
  reply.payload_bytes = ThreadPayload(bytes: @[])
  if payload != NIL:
    let serialized = serialize_literal(payload)
    reply.payload_bytes.bytes = string_to_bytes(serialized.to_s())
  reply.from_message_id = msg.id
  reply.from_thread_id = current_thread_id
  reply.from_thread_secret = THREADS[current_thread_id].secret
  next_message_id.inc()
  THREAD_DATA[msg.from_thread_id].channel.send(reply)

proc send_actor_failure(msg: ThreadMessage, message: string) =
  let error_payload = new_map_value()
  map_data(error_payload)["__thread_error__".to_key()] = true.to_value()
  map_data(error_payload)["message".to_key()] = message.to_value()
  send_actor_reply(msg, error_payload)

proc decode_actor_payload(msg: ThreadMessage): tuple[actor_id: int, payload: Value] =
  var envelope = msg.payload
  if msg.payload_bytes.bytes.len > 0:
    envelope = deserialize_literal(bytes_to_string(msg.payload_bytes.bytes))
  if envelope.kind != VkMap:
    raise new_exception(types.Exception, "Actor message envelope must be a map")
  let actor_id_key = actor_envelope_actor_id_key()
  let payload_key = actor_envelope_payload_key()
  if not map_data(envelope).hasKey(actor_id_key):
    raise new_exception(types.Exception, "Actor message envelope missing actor id")
  let actor_id_value = map_data(envelope)[actor_id_key]
  if actor_id_value.kind != VkInt:
    raise new_exception(types.Exception, "Actor message envelope actor id must be an int")
  result.actor_id = actor_id_value.int64.int
  result.payload = map_data(envelope).getOrDefault(payload_key, NIL)

proc actor_lookup(actor_id: int): ActorRuntimeRecord =
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)
  actor_registry.getOrDefault(actor_id)

proc actor_process_message(msg: ThreadMessage) =
  let (actor_id, payload) = decode_actor_payload(msg)
  let record = actor_lookup(actor_id)
  if record == nil:
    if msg.msg_type == MtSendExpectReply:
      send_actor_failure(msg, "Actor is no longer valid")
    return

  acquire(record.lock)
  if record.stopped:
    release(record.lock)
    if msg.msg_type == MtSendExpectReply:
      send_actor_failure(msg, "Actor is stopped")
    return
  let actor_state = record.state
  let handler = record.handler
  release(record.lock)

  current_actor_record = record
  current_actor_message = msg
  current_actor_reply_sent = false

  let ctx = ActorContext(actor: record.actor)

  try:
    let next_state =
      case handler.kind
      of VkFunction, VkBlock:
        vm_exec_callable(VM, handler, @[ctx.to_value(), payload, actor_state])
      of VkNativeFn:
        call_native_fn(handler.ref.native_fn, VM, @[ctx.to_value(), payload, actor_state])
      else:
        raise new_exception(types.Exception, "Actor handler must be callable")

    acquire(record.lock)
    record.state = next_state
    let is_stopped = record.stopped
    release(record.lock)

    if msg.msg_type == MtSendExpectReply and not current_actor_reply_sent and not is_stopped:
      send_actor_reply(msg, NIL)
  except CatchableError as exc:
    if msg.msg_type == MtSendExpectReply and not current_actor_reply_sent:
      send_actor_failure(msg, exc.msg)
  finally:
    current_actor_record = nil
    current_actor_message = nil
    current_actor_reply_sent = false

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

proc actor_send_internal(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                         has_keyword_args: bool, reply_requested: bool): Value =
  if get_method_arg_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "Actor.send requires a message")

  let self_arg = get_self(args, has_keyword_args)
  let payload = get_method_arg(args, 0, has_keyword_args)
  let record = actor_record_from_value(self_arg)

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

  let envelope = new_map_value()
  map_data(envelope)[actor_envelope_actor_id_key()] = record.actor.id.to_value()
  map_data(envelope)[actor_envelope_payload_key()] = payload
  let serialized = serialize_literal(envelope)

  var msg: ThreadMessage
  new(msg)
  msg.id = next_message_id
  msg.msg_type = if reply_requested: MtSendExpectReply else: MtSend
  msg.payload = NIL
  msg.payload_bytes = ThreadPayload(bytes: string_to_bytes(serialized.to_s()))
  msg.code = NIL
  msg.from_thread_id = current_thread_id
  msg.from_thread_secret = THREADS[current_thread_id].secret
  let message_id = next_message_id
  next_message_id.inc()

  THREAD_DATA[thread_id].channel.send(msg)

  if reply_requested:
    let future_obj = FutureObj(
      state: FsPending,
      value: NIL,
      success_callbacks: @[],
      failure_callbacks: @[],
      nim_future: nil
    )
    vm.thread_futures[message_id] = future_obj
    vm.poll_enabled = true

    let future_val = new_ref(VkFuture)
    future_val.future = future_obj
    return future_val.to_ref_value()

  NIL

proc actor_send_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    actor_send_internal(vm, args, arg_count, has_keyword_args, false)

proc actor_send_expect_reply_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                    has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    actor_send_internal(vm, args, arg_count, has_keyword_args, true)

proc actor_enable_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value =
  discard vm
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)

  if actor_system_enabled:
    raise new_exception(types.Exception, "gene/actor/enable can only be called once")
  if actor_spawned:
    raise new_exception(types.Exception, "gene/actor/enable must run before actors are spawned")

  let available_workers = max(0, g_max_threads - 1)
  if available_workers == 0:
    raise new_exception(types.Exception, "Actor runtime requires at least one worker thread")

  var worker_count = min(available_workers, max(1, countProcessors()))
  if has_keyword_args and has_keyword_arg(args, "workers"):
    let workers_arg = get_keyword_arg(args, "workers")
    if workers_arg.kind != VkInt:
      raise new_exception(types.Exception, "gene/actor/enable ^workers expects an integer")
    worker_count = workers_arg.int64.int
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

  actor_system_enabled = true
  NIL

proc actor_enable_native*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                          has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    actor_enable_impl(vm, args, arg_count, has_keyword_args)

proc actor_spawn_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                      has_keyword_args: bool): Value =
  discard vm
  if get_positional_count(arg_count, has_keyword_args) != 1:
    raise new_exception(types.Exception, "gene/actor/spawn expects exactly one handler")

  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)

  if not actor_system_enabled:
    raise new_exception(types.Exception, "gene/actor/spawn requires gene/actor/enable first")
  if actor_worker_ids.len == 0:
    raise new_exception(types.Exception, "Actor runtime has no available workers")

  let handler = get_positional_arg(args, 0, has_keyword_args)
  if handler.kind notin {VkFunction, VkNativeFn, VkBlock}:
    raise new_exception(types.Exception, "gene/actor/spawn expects a callable handler")

  if handler.kind == VkFunction:
    discard freeze_value(handler)

  let state =
    if has_keyword_args and has_keyword_arg(args, "state"): get_keyword_arg(args, "state")
    else: NIL

  let worker_id = actor_worker_ids[actor_rr_index mod actor_worker_ids.len]
  actor_rr_index.inc()

  let actor_handle = Actor(id: actor_next_id)
  actor_next_id.inc()
  let record = ActorRuntimeRecord(
    actor: actor_handle,
    thread_id: worker_id,
    handler: handler,
    state: state,
    stopped: false
  )
  initLock(record.lock)
  actor_registry[actor_handle.id] = record
  actor_spawned = true
  actor_handle.to_value()

proc actor_spawn_native*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                         has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    actor_spawn_impl(vm, args, arg_count, has_keyword_args)

proc actor_stop_impl(args: ptr UncheckedArray[Value], has_keyword_args: bool): Value =
  let record = actor_record_from_value(get_self(args, has_keyword_args))
  acquire(record.lock)
  record.stopped = true
  release(record.lock)
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

proc actor_context_reply_impl(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if get_method_arg_count(arg_count, has_keyword_args) < 1:
    raise new_exception(types.Exception, "ActorContext.reply requires a value")
  if current_actor_message == nil or current_actor_message.msg_type != MtSendExpectReply:
    raise new_exception(types.Exception, "ActorContext.reply requires send_expect_reply")
  if current_actor_reply_sent:
    raise new_exception(types.Exception, "ActorContext.reply can only be called once per message")
  send_actor_reply(current_actor_message, get_method_arg(args, 0, has_keyword_args))
  current_actor_reply_sent = true
  NIL

proc actor_context_reply_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  {.cast(gcsafe).}:
    actor_context_reply_impl(args, arg_count, has_keyword_args)

proc actor_context_stop_impl(): Value =
  if current_actor_record != nil:
    acquire(current_actor_record.lock)
    current_actor_record.stopped = true
    release(current_actor_record.lock)
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
  acquire(actor_runtime_lock)
  defer: release(actor_runtime_lock)
  actor_system_enabled = false
  actor_spawned = false
  actor_next_id = 1
  actor_worker_ids = @[]
  actor_registry = initTable[int, ActorRuntimeRecord]()
  actor_rr_index = 0

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
