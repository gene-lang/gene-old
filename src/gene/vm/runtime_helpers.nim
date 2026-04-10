# ========== Threading Support ==========

const VmThreadLogger = "gene/vm/thread"

proc current_trace(self: ptr VirtualMachine): SourceTrace =
  if self.cu.is_nil:
    return nil
  if self.pc >= 0 and self.pc < self.cu.instruction_traces.len:
    let trace = self.cu.instruction_traces[self.pc]
    if trace.is_nil and not self.cu.trace_root.is_nil:
      return self.cu.trace_root
    return trace
  if not self.cu.trace_root.is_nil:
    return self.cu.trace_root
  nil

proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string =
  let trace = self.current_trace()
  var detail: string
  if value.kind == VkInstance:
    let exception_class_val = App.app.exception_class
    var is_exception = false
    if exception_class_val.kind == VkClass:
      var cls = value.instance_class
      while cls != nil:
        if cls == exception_class_val.ref.class:
          is_exception = true
          break
        cls = cls.parent
    if is_exception:
      if "message".to_key() in instance_props(value):
        let msg_val = instance_props(value)["message".to_key()]
        detail = if msg_val.kind == VkString: msg_val.str else: $msg_val
      else:
        detail = $value
    else:
      detail = $value
  else:
    detail = $value

  if is_diagnostic_envelope(detail):
    return detail

  let (file, line, column) =
    if trace != nil: (trace.filename, trace.line, trace.column)
    else: ("", 0, 0)

  make_diagnostic_message(
    code = infer_diag_code(detail),
    message = detail,
    file = file,
    line = line,
    column = column
  )

proc ensure_frame_pool() =
  ## Lazily allocate the shared frame pool for this thread.
  if FRAMES.len == 0:
    FRAMES = newSeqOfCap[Frame](INITIAL_FRAME_POOL_SIZE)
    for i in 0..<INITIAL_FRAME_POOL_SIZE:
      FRAMES.add(cast[Frame](alloc0(sizeof(FrameObj))))
      FRAME_ALLOCS.inc()

proc new_thread_vm*(): ptr VirtualMachine =
  ## Create a VM instance for a worker thread (App/shared bits are populated elsewhere).
  new_vm_ptr()

proc create_thread_namespace*(thread_id: int): Namespace =
  ## Build the thread-local namespace with thread metadata.
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

proc setup_thread_vm(thread_id: int) =
  ## Centralized per-thread VM initialization (no App mutations).
  current_thread_id = thread_id
  VM = new_thread_vm()
  ensure_frame_pool()
  VM.thread_local_ns = create_thread_namespace(thread_id)
  gene_namespace_initialized = true
  init_thread_class()

proc reset_thread_vm_state() =
  ## Reset VM state between jobs (reuse allocations/pools).
  reset_vm_state()

when not defined(gene_wasm):
  # VM initialization for worker threads
  proc init_vm_for_thread*(thread_id: int) =
    ## Initialize VM for a worker thread
    ## Note: App is shared from main thread, only VM is thread-local
    setup_thread_vm(thread_id)

  # Thread handler
  proc thread_handler*(thread_id: int) {.thread.} =
    ## Main thread execution loop
    {.cast(gcsafe).}:
      try:
        # Initialize VM for this thread
        init_vm_for_thread(thread_id)

        # Message loop
        when DEBUG_VM:
          log_message(LlDebug, VmThreadLogger, "Starting message loop for thread " & $thread_id)
        while true:
          # Receive message (blocking)
          let msg = THREAD_DATA[thread_id].channel.recv()

          # Check for termination
          if msg.msg_type == MtTerminate:
            break

          # Reset VM state from previous execution
          reset_thread_vm_state()

          # Execute based on message type
          case msg.msg_type:
          of MtRun, MtRunExpectReply:
            try:
              # Compile the Gene AST locally (thread-safe, no shared refs)
              when DEBUG_VM:
                log_message(LlDebug, VmThreadLogger, "Compiling code: " & $msg.code)
              let cu = compile_init(msg.code)

              # Set up VM with scope tracker
              let scope_tracker = new_scope_tracker()
              VM.frame = new_frame()
              VM.frame.stack_index = 0
              VM.frame.scope = new_scope(scope_tracker)
              VM.frame.ns = App.app.gene_ns.ref.ns  # Set namespace for symbol lookup
              VM.cu = cu
              VM.pc = 0

              # Execute
              let result = VM.exec()

              # Send reply if requested
              if msg.msg_type == MtRunExpectReply:
                let ser = serialize_literal(result)
                let reply = ThreadMessage(
                  id: next_message_id,
                  msg_type: MtReply,
                  payload: NIL,
                  payload_bytes: ThreadPayload(bytes: string_to_bytes(ser.to_s())),
                  from_message_id: msg.id,
                  from_thread_id: thread_id,
                  from_thread_secret: THREADS[thread_id].secret
                )
                next_message_id += 1
                THREAD_DATA[msg.from_thread_id].channel.send(reply)
            except CatchableError as e:
              when not defined(release):
                log_message(LlError, VmThreadLogger, "Thread " & $thread_id & " handler error: " & e.msg)
                log_message(LlDebug, VmThreadLogger, e.getStackTrace())
              if msg.msg_type == MtRunExpectReply:
                let error_payload = new_map_value()
                map_data(error_payload)["__thread_error__".to_key()] = true.to_value()
                map_data(error_payload)["message".to_key()] = e.msg.to_value()
                let ser = serialize_literal(error_payload)
                let reply = ThreadMessage(
                  id: next_message_id,
                  msg_type: MtReply,
                  payload: NIL,
                  payload_bytes: ThreadPayload(bytes: string_to_bytes(ser.to_s())),
                  from_message_id: msg.id,
                  from_thread_id: thread_id,
                  from_thread_secret: THREADS[thread_id].secret
                )
                next_message_id += 1
                THREAD_DATA[msg.from_thread_id].channel.send(reply)

          of MtSend, MtSendExpectReply:
            # User message - invoke callbacks
            # Deserialize payload if present
            var payload = msg.payload
            if msg.payload_bytes.bytes.len > 0:
              try:
                payload = deserialize_literal(bytes_to_string(msg.payload_bytes.bytes))
              except:
                payload = NIL
            let msg_value = msg.to_value()
            msg_value.ref.thread_message.payload = payload

            # Invoke all registered message callbacks
            for callback in VM.message_callbacks:
              try:
                case callback.kind:
                of VkFunction:
                  discard VM.exec_function(callback, @[msg_value])
                of VkNativeFn:
                  discard call_native_fn(callback.ref.native_fn, VM, @[msg_value])
                of VkBlock:
                  discard VM.exec_function(callback, @[])
                else:
                  discard
              except:
                discard  # Ignore callback errors for now

            # If message requests reply and wasn't handled, send NIL reply
            if msg.msg_type == MtSendExpectReply and not msg.handled:
              var reply: ThreadMessage
              new(reply)
              reply.id = next_message_id
              reply.msg_type = MtReply
              reply.payload = NIL
              reply.payload_bytes = ThreadPayload(bytes: @[])
              reply.from_message_id = msg.id
              reply.from_thread_id = thread_id
              reply.from_thread_secret = THREADS[thread_id].secret
              next_message_id += 1
              THREAD_DATA[msg.from_thread_id].channel.send(reply)

          of MtReply:
            discard

          of MtTerminate:
            break

      except CatchableError as e:
        log_message(LlError, VmThreadLogger, "Thread " & $thread_id & " crashed: " & e.msg)
        when not defined(release):
          log_message(LlDebug, VmThreadLogger, e.getStackTrace())
      finally:
        if VM != nil:
          free_vm_ptr(VM)
          VM = nil
        cleanup_thread(thread_id)

  # Spawn functions
  proc spawn_thread(code: Value, return_value: bool): Value =
    ## Spawn a new thread to execute code payload.
    ## Payload can be a form, stream, or literal expression.
    ## Returns thread reference or future
    let thread_id = get_free_thread()

    if thread_id == -1:
      raise newException(ValueError, "Thread pool exhausted (max " & $MAX_THREADS & " threads)")

    # Initialize thread
    let parent_id = current_thread_id
    init_thread(thread_id, parent_id)

    # Create thread
    createThread(THREAD_DATA[thread_id].thread, thread_handler, thread_id)

    # Create message - use new() to allocate to avoid GC issues with threading
    var msg: ThreadMessage
    new(msg)
    msg.id = next_message_id
    msg.msg_type = if return_value: MtRunExpectReply else: MtRun
    msg.payload = NIL
    msg.payload_bytes = ThreadPayload(bytes: @[])
    msg.code = code
    msg.from_thread_id = current_thread_id
    msg.from_thread_secret = THREADS[current_thread_id].secret
    let message_id = next_message_id
    next_message_id += 1

    # Send message to thread (send the ref directly)
    THREAD_DATA[thread_id].channel.send(msg)

    # Return value
    if return_value:
      # Create a future for the return value
      let future_obj = FutureObj(
        state: FsPending,
        value: NIL,
        success_callbacks: @[],
        failure_callbacks: @[],
        nim_future: nil
      )

      # Store future in VM's thread_futures table keyed by message ID
      VM.thread_futures[message_id] = future_obj
      VM.poll_enabled = true

      # Return the future
      let future_val = new_ref(VkFuture)
      future_val.future = future_obj
      return future_val.to_ref_value()
    else:
      # Return thread reference
      let thread_ref = types.Thread(
        id: thread_id,
        secret: THREADS[thread_id].secret
      )
      return thread_ref.to_value()
else:
  proc init_vm_for_thread*(thread_id: int) =
    discard thread_id

  proc spawn_thread(code: Value, return_value: bool): Value =
    discard code
    discard return_value
    raise_wasm_unsupported("threads")

# ========== End Threading Support ==========
