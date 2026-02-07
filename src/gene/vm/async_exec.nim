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

proc execute_future_callbacks*(self: ptr VirtualMachine, future_obj: FutureObj) =
  ## Execute success or failure callbacks for a completed future
  ## This should be called when a future completes OR when callbacks are added to an already-completed future
  if future_obj.state == FsSuccess:
    # Execute success callbacks
    for callback in future_obj.success_callbacks:
      try:
        case callback.kind:
          of VkFunction, VkBlock:
            discard self.exec_function(callback, @[future_obj.value])
          of VkNativeFn:
            var args_arr = [future_obj.value]
            discard call_native_fn(callback.ref.native_fn, self, args_arr)
          else:
            discard
      except CatchableError:
        # If callback throws, mark future as failed
        future_obj.state = FsFailure
        future_obj.value = self.current_exception
        break
    # Clear callbacks after execution
    future_obj.success_callbacks.setLen(0)

  elif future_obj.state == FsFailure:
    # Execute failure callbacks
    for callback in future_obj.failure_callbacks:
      try:
        case callback.kind:
          of VkFunction, VkBlock:
            discard self.exec_function(callback, @[future_obj.value])
          of VkNativeFn:
            var args_arr = [future_obj.value]
            discard call_native_fn(callback.ref.native_fn, self, args_arr)
          else:
            discard
      except CatchableError:
        # If callback throws, keep failure state but replace value
        future_obj.value = self.current_exception
        break
    # Clear callbacks after execution
    future_obj.failure_callbacks.setLen(0)

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

        echo "DEBUG: poll_event_loop received message!"
        let msg = msg_opt.get()
        echo "DEBUG: Message type: ", msg.msg_type, ", from_message_id: ", msg.from_message_id
        if msg.msg_type == MtReply:
          # Complete the future with the reply payload
          if self.thread_futures.hasKey(msg.from_message_id):
            echo "DEBUG: Found matching future, completing it"
            let future_obj = self.thread_futures[msg.from_message_id]
            var payload = msg.payload
            if msg.payload_bytes.bytes.len > 0:
              try:
                echo "DEBUG: Deserializing payload..."
                payload = deserialize_literal(bytes_to_string(msg.payload_bytes.bytes))
                echo "DEBUG: Payload deserialized successfully"
              except CatchableError as ex:
                echo "DEBUG: Deserialization failed: ", ex.msg
                future_obj.state = FsFailure
                future_obj.value = wrap_nim_exception(ex, "thread reply decode")
                # Execute callbacks inline
                self.execute_future_callbacks(future_obj)
                # Fail the attached Nim future if present
                if future_obj.nim_future != nil and not future_obj.nim_future.finished:
                  future_obj.nim_future.fail(newException(system.Exception, ex.msg))
                self.thread_futures.del(msg.from_message_id)
                continue
            let error_msg = thread_error_message(payload)
            if error_msg.len > 0:
              echo "DEBUG: Thread reply indicates error: ", error_msg
              let ex = new_exception(types.Exception, error_msg)
              future_obj.state = FsFailure
              future_obj.value = wrap_nim_exception(ex, "thread reply")
              # Execute callbacks inline
              self.execute_future_callbacks(future_obj)
              # Fail the attached Nim future if present
              if future_obj.nim_future != nil and not future_obj.nim_future.finished:
                future_obj.nim_future.fail(newException(system.Exception, error_msg))
              self.thread_futures.del(msg.from_message_id)
              continue
            future_obj.state = FsSuccess
            future_obj.value = payload
            echo "DEBUG: Future state set to success"
            # Execute callbacks inline
            self.execute_future_callbacks(future_obj)
            echo "DEBUG: Callbacks executed"
            # Complete the attached Nim future if present (for non-blocking HTTP handlers)
            if future_obj.nim_future != nil and not future_obj.nim_future.finished:
              echo "DEBUG: Completing Nim future..."
              future_obj.nim_future.complete(payload)
              echo "DEBUG: Nim future completed!"
            else:
              echo "DEBUG: No Nim future to complete or already finished"
            self.thread_futures.del(msg.from_message_id)
            echo "DEBUG: Future removed from table"

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
