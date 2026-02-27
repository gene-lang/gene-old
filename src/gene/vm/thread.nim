import locks, random, options, tables, os
import ../types
import ../serdes
import ./utils

# Simple channel implementation for MVP
type
  Channel*[T] = ptr ChannelObj[T]

  ChannelObj*[T] = object
    lock: Lock
    cond: Cond
    data: seq[T]
    capacity: int
    closed: bool

proc open*[T](ch: var Channel[T], capacity: int) =
  if ch != nil:
    return  # Already opened
  ch = cast[Channel[T]](alloc0(sizeof(ChannelObj[T])))
  initLock(ch.lock)
  initCond(ch.cond)
  ch.data = newSeq[T](0)
  ch.capacity = capacity
  ch.closed = false

proc close*[T](ch: Channel[T]) =
  if ch == nil:
    return
  acquire(ch.lock)
  ch.closed = true
  broadcast(ch.cond)
  release(ch.lock)

proc send*[T](ch: Channel[T], item: T) =
  acquire(ch.lock)

  # Wait if full
  while ch.data.len >= ch.capacity and not ch.closed:
    wait(ch.cond, ch.lock)

  if not ch.closed:
    ch.data.add(item)
    signal(ch.cond)

  release(ch.lock)

proc recv*[T](ch: Channel[T]): T =
  acquire(ch.lock)

  # Wait for data
  while ch.data.len == 0 and not ch.closed:
    wait(ch.cond, ch.lock)

  if ch.data.len > 0:
    result = ch.data[0]
    ch.data.delete(0)
    signal(ch.cond)

  release(ch.lock)

proc try_recv*[T](ch: Channel[T]): Option[T] =
  ## Non-blocking receive - returns Some(value) if data available, None otherwise
  acquire(ch.lock)

  if ch.data.len > 0:
    result = some(ch.data[0])
    ch.data.delete(0)
    signal(ch.cond)
  else:
    result = none(T)

  release(ch.lock)

# Thread-local channel and threading data
type
  ThreadChannel* = Channel[ThreadMessage]  # Store refs directly, not pointers

  ThreadDataObj* = object
    thread*: system.Thread[int]
    channel*: ThreadChannel

var THREAD_DATA*: array[MAX_THREADS, ThreadDataObj]  # Shared across threads (channels are thread-safe)
var THREAD_CLASS_VALUE*: Value  # Cached thread class value for quick access across threads
var THREAD_MESSAGE_CLASS_VALUE*: Value

# Thread pool management
var thread_pool_lock: Lock
var next_message_id* {.threadvar.}: int

proc init_thread_pool*() =
  ## Initialize the thread pool (call once from main thread)
  randomize()  # Initialize random number generator
  initLock(thread_pool_lock)
  next_message_id = 0

  # Terminate and clean up any existing worker threads/channels
  for i in 1..<MAX_THREADS:
    if THREAD_DATA[i].channel != nil:
      # Ask the worker to exit and wait for it to finish
      var term: ThreadMessage
      new(term)
      term.id = next_message_id
      term.msg_type = MtTerminate
      term.payload = NIL
      term.payload_bytes = ThreadPayload(bytes: @[])
      term.from_thread_id = 0
      term.from_thread_secret = THREADS[0].secret
      THREAD_DATA[i].channel.send(term)
      # Join the thread if it was ever started
      if THREADS[i].in_use or THREADS[i].state != TsFree:
        joinThread(THREAD_DATA[i].thread)
      close(THREAD_DATA[i].channel)
      THREAD_DATA[i].channel = nil
    # Reset metadata
    THREADS[i].id = i
    THREADS[i].state = TsFree
    THREADS[i].in_use = false
    THREADS[i].parent_id = 0
    THREADS[i].parent_secret = 0
    THREADS[i].secret = 0

  # Reset main thread channel if it was previously opened
  if THREAD_DATA[0].channel != nil:
    close(THREAD_DATA[0].channel)
    THREAD_DATA[0].channel = nil

  # Initialize thread 0 as main thread
  THREADS[0].id = 0
  THREADS[0].secret = rand(int.high)
  THREADS[0].state = TsBusy
  THREADS[0].in_use = true
  THREADS[0].parent_id = 0
  THREADS[0].parent_secret = THREADS[0].secret

  THREAD_DATA[0].channel.open(CHANNEL_LIMIT)

  # Initialize other thread slots as free
  for i in 1..<MAX_THREADS:
    THREADS[i].id = i
    THREADS[i].state = TsFree
    THREADS[i].in_use = false

proc get_free_thread*(): int =
  ## Find and allocate a free thread slot
  ## Returns -1 if no threads available
  acquire(thread_pool_lock)
  defer: release(thread_pool_lock)

  for i in 1..<MAX_THREADS:
    if not THREADS[i].in_use and THREADS[i].state == TsFree:
      THREADS[i].in_use = true
      THREADS[i].state = TsBusy
      THREADS[i].secret = rand(int.high)
      return i
  return -1

proc init_thread*(thread_id: int, parent_id: int = 0) =
  ## Initialize thread metadata
  THREADS[thread_id].id = thread_id
  THREADS[thread_id].parent_id = parent_id
  THREADS[thread_id].parent_secret = THREADS[parent_id].secret
  THREADS[thread_id].state = TsBusy

  # Open channel for this thread
  THREAD_DATA[thread_id].channel.open(CHANNEL_LIMIT)

proc cleanup_thread*(thread_id: int) =
  ## Clean up thread and mark as free
  acquire(thread_pool_lock)
  defer: release(thread_pool_lock)

  THREADS[thread_id].state = TsFree
  THREADS[thread_id].in_use = false
  THREADS[thread_id].secret = rand(int.high)  # Rotate secret

  # Close channel
  THREAD_DATA[thread_id].channel.close()

# VM state reset
proc reset_vm_state*() =
  ## Reset VM state for thread reuse
  VM.pc = 0
  VM.cu = nil
  VM.trace = false

  # Return all frames to pool
  var current_frame = VM.frame
  while current_frame != nil:
    let caller = current_frame.caller_frame
    current_frame.free()
    current_frame = caller
  VM.frame = nil

  # Clear exception handlers
  VM.exception_handlers.setLen(0)
  VM.current_exception = NIL
  VM.repl_exception = NIL
  VM.repl_on_error = false
  VM.repl_active = false
  VM.repl_skip_on_throw = false
  VM.repl_ran = false
  VM.repl_resume_value = NIL

  # Clear generator state
  VM.current_generator = nil

# Thread pool initialization must be called from main thread
# This will be called from vm.nim

# Thread class initialization
proc init_thread_class*() =
  ## Initialize Thread class and methods
  ## Called during VM initialization
  if not gene_namespace_initialized:
    return

  # Check if already initialized (idempotency for worker threads)
  # Prevents worker threads from racing to mutate shared App
  if App.app.thread_class.kind == VkClass:
    THREAD_CLASS_VALUE = App.app.thread_class
    THREAD_MESSAGE_CLASS_VALUE = App.app.thread_message_class
    return

  # Create Thread class
  let thread_class = new_class("Thread")
  # Don't set parent yet - will be set later when object_class is available

  # Add Thread constructor (not typically called directly - threads created via spawn)
  proc thread_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    raise new_exception(types.Exception, "Thread cannot be constructed directly - use spawn or spawn_return")

  thread_class.def_native_constructor(thread_constructor)

  # Add .send methods
  proc thread_send_internal(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool, force_reply: bool): Value {.gcsafe.} =
    if arg_count < 2:
      raise new_exception(types.Exception, "Thread.send requires a thread and a message")

    let thread_arg = get_positional_arg(args, 0, has_keyword_args)
    let message_arg = get_positional_arg(args, 1, has_keyword_args)

    if thread_arg.kind != VkThread:
      raise new_exception(types.Exception, "send can only be called on a Thread")

    # Check if reply is requested
    let reply_val =
      if force_reply: TRUE
      elif has_keyword_args: get_keyword_arg(args, "reply")
      elif arg_count > 2: args[2]
      else: NIL
    let reply_requested = reply_val != NIL and reply_val.to_bool()

    # Get thread info
    let thread_id = thread_arg.ref.thread.id
    let thread_secret = thread_arg.ref.thread.secret

    # Validate thread
    if thread_id < 0 or thread_id >= MAX_THREADS:
      raise new_exception(types.Exception, "Invalid thread ID")
    if not THREADS[thread_id].in_use or THREADS[thread_id].secret != thread_secret:
      raise new_exception(types.Exception, "Thread is no longer valid")

    # Create message
    var msg: ThreadMessage
    new(msg)
    msg.id = next_message_id
    msg.msg_type = if reply_requested: MtSendExpectReply else: MtSend
    msg.payload = NIL

    # Serialize payload to isolate across threads
    # NOTE: Only literal values are allowed (primitives, strings, and containers with literal contents).
    # Functions, classes, instances, threads, futures are NOT allowed.
    # See serialize_literal in serdes.nim for detailed rationale.
    let ser = serialize_literal(message_arg)
    let ser_str = block:
      {.cast(gcsafe).}:
        ser.to_s()
    msg.payload_bytes.bytes = string_to_bytes(ser_str)
    msg.code = NIL
    msg.from_thread_id = current_thread_id
    msg.from_thread_secret = THREADS[current_thread_id].secret
    let message_id = next_message_id
    next_message_id += 1

    # Send message to thread
    THREAD_DATA[thread_id].channel.send(msg)

    # Return value
    if reply_requested:
      # Create a future for the reply
      let future_obj = FutureObj(
        state: FsPending,
        value: NIL,
        success_callbacks: @[],
        failure_callbacks: @[],
        nim_future: nil
      )

      # Store future in vm's thread_futures table keyed by message ID
      vm.thread_futures[message_id] = future_obj
      vm.poll_enabled = true

      # Return the future
      let future_val = new_ref(VkFuture)
      future_val.future = future_obj
      return future_val.to_ref_value()
    else:
      return NIL

  thread_class.def_native_method("send", (proc (vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = thread_send_internal(vm, args, arg_count, has_keyword_args, false)))
  thread_class.def_native_method("send_expect_reply", (proc (vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} = thread_send_internal(vm, args, arg_count, has_keyword_args, true)))

  # Add .on_message method
  proc thread_on_message(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    # Register callback for incoming messages
    # Usage: (.on_message $thread callback)
    if arg_count < 2:
      raise new_exception(types.Exception, "Thread.on_message requires a thread and a callback")

    let thread_arg = get_positional_arg(args, 0, has_keyword_args)
    let callback_arg = get_positional_arg(args, 1, has_keyword_args)

    if thread_arg.kind != VkThread:
      raise new_exception(types.Exception, "on_message can only be called on a Thread")

    # Validate callback is callable
    if callback_arg.kind notin {VkFunction, VkNativeFn, VkBlock}:
      raise new_exception(types.Exception, "on_message callback must be a function or block")

    # Add callback to VM's message_callbacks list
    vm.message_callbacks.add(callback_arg)

    return NIL

  thread_class.def_native_method("on_message", thread_on_message)

  # Store in Application
  let thread_class_ref = new_ref(VkClass)
  thread_class_ref.class = thread_class
  App.app.thread_class = thread_class_ref.to_ref_value()
  THREAD_CLASS_VALUE = App.app.thread_class

  # Add to gene namespace if it exists
  if App.app.gene_ns.kind == VkNamespace:
    let thread_key = "Thread".to_key()
    App.app.gene_ns.ref.ns[thread_key] = App.app.thread_class
    # Global helper to force reply expectation
    proc thread_send_expect_reply_fn(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
      thread_send_internal(vm, args, arg_count, has_keyword_args, true)
    App.app.gene_ns.ref.ns["send_expect_reply".to_key()] = (cast[NativeFn](thread_send_expect_reply_fn)).to_value()

  # Create ThreadMessage class
  let thread_message_class = new_class("ThreadMessage")

  # Add .payload method
  proc thread_message_payload(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "ThreadMessage.payload requires self argument")

    let msg_arg = get_positional_arg(args, 0, has_keyword_args)
    if msg_arg.kind != VkThreadMessage:
      raise new_exception(types.Exception, "payload can only be called on a ThreadMessage")

    return msg_arg.ref.thread_message.payload

  thread_message_class.def_native_method("payload", thread_message_payload)

  # Add .reply method
  proc thread_message_reply(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if arg_count < 2:
      raise new_exception(types.Exception, "ThreadMessage.reply requires a message and a value")

    let msg_arg = get_positional_arg(args, 0, has_keyword_args)
    let value_arg = get_positional_arg(args, 1, has_keyword_args)

    if msg_arg.kind != VkThreadMessage:
      raise new_exception(types.Exception, "reply can only be called on a ThreadMessage")

    let msg = msg_arg.ref.thread_message

    # Create reply message
    var reply: ThreadMessage
    new(reply)
    reply.id = next_message_id
    reply.msg_type = MtReply
    reply.payload = NIL
    let ser = serialize_literal(value_arg)
    let ser_str = block:
      {.cast(gcsafe).}:
        ser.to_s()
    reply.payload_bytes.bytes = string_to_bytes(ser_str)
    reply.from_message_id = msg.id
    reply.from_thread_id = current_thread_id
    reply.from_thread_secret = THREADS[current_thread_id].secret
    next_message_id += 1

    # Send reply to sender
    THREAD_DATA[msg.from_thread_id].channel.send(reply)

    # Mark message as handled
    msg.handled = true

    return NIL

  thread_message_class.def_native_method("reply", thread_message_reply)

  # Store ThreadMessage class
  let thread_message_class_ref = new_ref(VkClass)
  thread_message_class_ref.class = thread_message_class
  App.app.thread_message_class = thread_message_class_ref.to_ref_value()
  THREAD_MESSAGE_CLASS_VALUE = App.app.thread_message_class

  # Add to gene namespace if it exists
  if App.app.gene_ns.kind == VkNamespace:
    let thread_message_key = "ThreadMessage".to_key()
    App.app.gene_ns.ref.ns[thread_message_key] = App.app.thread_message_class

# keep_alive function - keeps thread running to receive messages
proc keep_alive_fn*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  ## Keep thread alive to receive messages
  ## Thread workers already stay alive in `thread_handler`; this function acts as
  ## a marker and optional bounded delay.
  ## Usage: (keep_alive) or (keep_alive timeout_ms)

  let positional_count = get_positional_count(arg_count, has_keyword_args)
  if positional_count == 0:
    return NIL

  let timeout_arg = get_positional_arg(args, 0, has_keyword_args)
  var timeout_ms: int
  case timeout_arg.kind:
  of VkInt:
    timeout_ms = timeout_arg.int64.int
  of VkFloat:
    timeout_ms = (timeout_arg.float64 * 1000.0).int
  else:
    raise new_exception(types.Exception, "keep_alive timeout must be a number (milliseconds or seconds)")

  if timeout_ms > 0:
    sleep(timeout_ms)

  return NIL
