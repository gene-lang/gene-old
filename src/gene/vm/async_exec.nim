## Async execution helpers: drain_pending_futures, execute_future_callbacks,
## setup_callback_execution, thread_error_message, poll_event_loop.
## Included from vm.nim — shares its scope.

proc drain_pending_futures(self: ptr VirtualMachine) =
  if self.pending_futures.len == 0 and self.thread_futures.len == 0:
    return
  var max_iterations = 100
  var iteration = 0
  while (self.pending_futures.len > 0 or self.thread_futures.len > 0) and iteration < max_iterations:
    iteration.inc()
    self.event_loop_counter = EVENT_LOOP_POLL_INTERVAL
    self.poll_enabled = true
    self.poll_event_loop()

    if self.pending_futures.len == 0 and self.thread_futures.len == 0:
      break

proc setup_callback_execution*(self: ptr VirtualMachine, callback: Value, arg: Value): bool =
  ## Sets up VM execution context for callback without executing it.
  ## Returns true if callback was set up, false if callback type not supported.
  ## After this returns true, the main exec loop will naturally run the callback.

  case callback.kind:
  of VkFunction:
    let f = callback.ref.fn
    if f.body_compiled == nil:
      f.compile()

    # Create scope for function
    var scope: Scope
    if f.matcher.is_empty():
      scope = f.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(f.scope_tracker, f.parent_scope)
      # Process the single argument
      var args_arr = [arg]
      process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args_arr[0].addr), 1, false, scope)

    # Create new frame
    var new_frame = new_frame()
    new_frame.kind = FkFunction
    let r = new_ref(VkFunction)
    r.fn = f
    new_frame.target = r.to_ref_value()
    new_frame.scope = scope
    new_frame.caller_frame = self.frame
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc)
    new_frame.ns = f.ns

    # Switch to new frame - main loop will execute it
    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    return true

  of VkBlock:
    let blk = callback.ref.block
    if blk.body_compiled == nil:
      blk.compile()

    var scope: Scope
    if blk.matcher.is_empty():
      scope = blk.frame.scope
    else:
      scope = new_scope(blk.scope_tracker, blk.frame.scope)
      var args_arr = [arg]
      process_args_direct(blk.matcher, cast[ptr UncheckedArray[Value]](args_arr[0].addr), 1, false, scope)

    var new_frame = new_frame()
    new_frame.kind = FkBlock
    let r = new_ref(VkBlock)
    r.block = blk
    new_frame.target = r.to_ref_value()
    new_frame.scope = scope
    new_frame.caller_frame = self.frame
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc)
    new_frame.ns = blk.ns

    self.frame = new_frame
    self.cu = blk.body_compiled
    self.pc = 0
    return true

  of VkNativeFn:
    # Native functions can be called directly - they don't need frame setup
    var args_arr = [arg]
    discard call_native_fn(callback.ref.native_fn, self, args_arr)
    return false  # Return false since we executed it directly

  else:
    return false

proc thread_error_message(payload: Value): string =
  if payload.kind != VkMap:
    return ""
  let err_key = "__thread_error__".to_key()
  if not map_data(payload).hasKey(err_key):
    return ""
  let flag = map_data(payload)[err_key]
  if flag == NIL or not flag.to_bool():
    return ""
  let msg_val = map_data(payload).getOrDefault("message".to_key(), "Thread error".to_value())
  if msg_val.kind == VkString:
    return msg_val.str
  return $msg_val

proc detach_future_tracking*(self: ptr VirtualMachine, future_obj: FutureObj) =
  ## Remove a future from all runtime tracking containers.
  var i = 0
  while i < self.pending_futures.len:
    if self.pending_futures[i] == future_obj:
      self.pending_futures.delete(i)
      continue
    i.inc()

  var remove_ids: seq[int] = @[]
  for message_id, tracked in self.thread_futures.pairs:
    if tracked == future_obj:
      remove_ids.add(message_id)
  for message_id in remove_ids:
    self.thread_futures.del(message_id)

  if self.pending_futures.len == 0 and self.thread_futures.len == 0:
    self.poll_enabled = false

proc poll_event_loop*(self: ptr VirtualMachine) =
  ## Periodically poll async/thread events; caller decides when to invoke.
  ## Callbacks are executed inline via exec_function.
  if not self.poll_enabled:
    return

  self.event_loop_counter.inc()
  if self.event_loop_counter >= EVENT_LOOP_POLL_INTERVAL:
    self.event_loop_counter = 0
    # Try to poll Nim async dispatcher, but ignore "no handles" error.
    try:
      poll(0)  # Non-blocking poll - check for completed async operations
    except ValueError:
      # Ignore "No handles or timers registered" - this is normal when using Gene futures
      discard

    # Check for thread replies (non-blocking)
    # Only check if we're the main thread (thread 0)
    if THREADS[0].in_use:
      while true:
        let msg_opt = THREAD_DATA[0].channel.try_recv()
        if msg_opt.isNone():
          break

        let msg = msg_opt.get()
        if msg.msg_type == MtReply:
          # Complete the future with the reply payload
          if self.thread_futures.hasKey(msg.from_message_id):
            let future_obj = self.thread_futures[msg.from_message_id]
            var payload = msg.payload
            if msg.payload_bytes.bytes.len > 0:
              try:
                payload = deserialize_literal(bytes_to_string(msg.payload_bytes.bytes))
              except CatchableError as ex:
                discard future_obj.fail(new_async_error("AIR.THREAD.REPLY.DECODE", ex.msg, "thread_reply_decode"))
                self.execute_future_callbacks(future_obj)
                # Fail the attached Nim future if present
                if future_obj.nim_future != nil and not future_obj.nim_future.finished:
                  future_obj.nim_future.fail(newException(system.Exception, ex.msg))
                self.thread_futures.del(msg.from_message_id)
                continue
            let error_msg = thread_error_message(payload)
            if error_msg.len > 0:
              discard future_obj.fail(new_async_error("AIR.THREAD.REPLY.FAILURE", error_msg, "thread_reply"))
              self.execute_future_callbacks(future_obj)
              # Fail the attached Nim future if present
              if future_obj.nim_future != nil and not future_obj.nim_future.finished:
                future_obj.nim_future.fail(newException(system.Exception, error_msg))
              self.thread_futures.del(msg.from_message_id)
              continue
            discard future_obj.complete(payload)
            # Execute callbacks inline
            self.execute_future_callbacks(future_obj)
            # Complete the attached Nim future if present (for non-blocking HTTP handlers)
            if future_obj.nim_future != nil and not future_obj.nim_future.finished:
              future_obj.nim_future.complete(payload)
            self.thread_futures.del(msg.from_message_id)

    # Remove any terminal thread futures that were cancelled/timed out externally.
    var terminal_ids: seq[int] = @[]
    for message_id, future_obj in self.thread_futures.pairs:
      if future_obj.state != FsPending:
        terminal_ids.add(message_id)
    for message_id in terminal_ids:
      self.thread_futures.del(message_id)

    # Update all pending futures from their Nim futures and execute callbacks inline
    var i = 0
    while i < self.pending_futures.len:
      let future_obj = self.pending_futures[i]
      update_future_from_nim(self, future_obj)

      # Execute callbacks inline if future completed
      if future_obj.state != FsPending:
        self.execute_future_callbacks(future_obj)

      # Remove completed futures with no remaining callbacks
      if future_obj.state != FsPending and
         future_obj.success_callbacks.len == 0 and
         future_obj.failure_callbacks.len == 0:
        self.pending_futures.delete(i)
        continue

      i.inc()

    if self.pending_futures.len == 0 and self.thread_futures.len == 0:
      self.poll_enabled = false
