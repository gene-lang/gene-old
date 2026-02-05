{.push warning[ResultShadowed]: off, warning[UnreachableCode]: off, warning[UnusedImport]: off.}

import tables, strutils, strformat, algorithm, options, streams
import times, os
import asyncdispatch  # For event loop polling in async support

import ./types
from ./types/runtime_types import validate_type
import ./compiler
from ./parser import read, read_all
import ./vm/args
import ./vm/module
import ./vm/utils
import ./serdes
import ./native/runtime
import ./native/hir
import ./native/trampoline
const DEBUG_VM = false
const
  CATCH_PC_ASYNC_BLOCK = -2
  CATCH_PC_ASYNC_FUNCTION = -3
  EVENT_LOOP_POLL_INTERVAL = 100

template is_method_frame(f: Frame): bool =
  f.kind in {FkMethod, FkMacroMethod}

template is_function_like(kind: FrameKind): bool =
  kind in {FkFunction, FkMethod, FkMacroMethod}

template same_value_identity(a: Value, b: Value): bool =
  cast[uint64](a) == cast[uint64](b)

proc expected_type_for(tracker: ScopeTracker, index: int): string {.inline.} =
  if tracker == nil:
    return ""
  if index < 0 or index >= tracker.type_expectations.len:
    return ""
  tracker.type_expectations[index]

proc native_args_supported(f: Function, args: seq[Value]): bool =
  const nativeArgLimit =
    when defined(arm64) or defined(aarch64):
      7
    elif defined(amd64):
      5
    else:
      0
  if nativeArgLimit == 0:
    return false
  if f.matcher.is_nil or not f.matcher.has_type_annotations:
    return false
  if f.matcher.children.len != args.len:
    return false
  if args.len > nativeArgLimit:
    return false
  for i, param in f.matcher.children:
    let type_name = param.type_name.toLowerAscii()
    if type_name in ["int", "int64", "i64"]:
      if args[i].kind != VkInt:
        return false
    elif type_name in ["float", "float64", "f64"]:
      if args[i].kind != VkFloat:
        return false
    else:
      return false
  true

proc native_trampoline*(
    ctx: ptr NativeContext,
    descriptor_idx: int64,
    args: ptr UncheckedArray[int64],
    argc: int64
): int64 {.cdecl, exportc.}

proc try_native_call(self: ptr VirtualMachine, f: Function, args: seq[Value], out_value: var Value): bool =
  if not self.native_code:
    return false
  if f.is_generator or f.async or f.is_macro_like:
    return false
  if not native_args_supported(f, args):
    return false
  if not f.native_ready:
    if f.native_failed:
      return false
    if f.body_compiled == nil:
      f.compile()
    let compiled = compile_to_native(f)
    if not compiled.ok:
      f.native_failed = true
      return false
    if f.native_descriptors.len > 0:
      release_descriptors(f.native_descriptors)
    f.native_entry = compiled.entry
    f.native_ready = true
    # Determine if return value is float (from HIR inference or explicit annotation)
    f.native_return_float = compiled.returnFloat
    f.native_descriptors = compiled.descriptors

  var ctx = NativeContext(
    vm: self,
    trampoline: cast[pointer](native_trampoline),
    descriptors: nil,
    descriptor_count: f.native_descriptors.len.int32
  )
  if f.native_descriptors.len > 0:
    ctx.descriptors = cast[ptr UncheckedArray[CallDescriptor]](f.native_descriptors[0].addr)

  # Convert args to int64 (uniform ABI: floats are bitcast to int64)
  proc arg_to_i64(v: Value): int64 {.inline.} =
    if v.kind == VkFloat:
      cast[int64](v.to_float())
    else:
      v.to_int()

  type
    NativeFn0 = proc(ctx: ptr NativeContext): int64 {.cdecl.}
    NativeFn1 = proc(ctx: ptr NativeContext, a0: int64): int64 {.cdecl.}
    NativeFn2 = proc(ctx: ptr NativeContext, a0, a1: int64): int64 {.cdecl.}
    NativeFn3 = proc(ctx: ptr NativeContext, a0, a1, a2: int64): int64 {.cdecl.}
    NativeFn4 = proc(ctx: ptr NativeContext, a0, a1, a2, a3: int64): int64 {.cdecl.}
    NativeFn5 = proc(ctx: ptr NativeContext, a0, a1, a2, a3, a4: int64): int64 {.cdecl.}
    NativeFn6 = proc(ctx: ptr NativeContext, a0, a1, a2, a3, a4, a5: int64): int64 {.cdecl.}
    NativeFn7 = proc(ctx: ptr NativeContext, a0, a1, a2, a3, a4, a5, a6: int64): int64 {.cdecl.}
  var result_i64: int64
  case args.len
  of 0:
    result_i64 = cast[NativeFn0](f.native_entry)(addr ctx)
  of 1:
    result_i64 = cast[NativeFn1](f.native_entry)(addr ctx, args[0].arg_to_i64())
  of 2:
    result_i64 = cast[NativeFn2](f.native_entry)(addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64())
  of 3:
    result_i64 = cast[NativeFn3](f.native_entry)(addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64())
  of 4:
    result_i64 = cast[NativeFn4](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64()
    )
  of 5:
    result_i64 = cast[NativeFn5](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64(), args[4].arg_to_i64()
    )
  of 6:
    result_i64 = cast[NativeFn6](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64(), args[4].arg_to_i64(), args[5].arg_to_i64()
    )
  of 7:
    result_i64 = cast[NativeFn7](f.native_entry)(
      addr ctx, args[0].arg_to_i64(), args[1].arg_to_i64(), args[2].arg_to_i64(), args[3].arg_to_i64(),
      args[4].arg_to_i64(), args[5].arg_to_i64(), args[6].arg_to_i64()
    )
  else:
    return false
  # Unbox result: if return type is float, bitcast int64 back to float64
  if f.native_return_float:
    out_value = cast[float64](result_i64).to_value()
  else:
    out_value = result_i64.to_value()
  true

proc skip_wildcard_import_key(key: Key): bool {.inline.} =
  key == "__module_name__".to_key() or
  key == "__is_main__".to_key() or
  key == "__init__".to_key() or
  key == "__init_ran__".to_key() or
  key == "__compiled__".to_key() or
  key == "__exports__".to_key() or
  key == "gene".to_key() or
  key == "genex".to_key()

proc resolve_local_or_namespace(self: ptr VirtualMachine, name: string): tuple[found: bool, value: Value] =
  let key = name.to_key()
  if self.frame != nil and self.frame.scope != nil and self.frame.scope.tracker != nil:
    let found = self.frame.scope.tracker.locate(key)
    if found.local_index >= 0:
      var scope = self.frame.scope
      var parent_index = found.parent_index
      while parent_index > 0 and scope != nil:
        parent_index.dec()
        scope = scope.parent
      if scope != nil and found.local_index < scope.members.len:
        return (true, scope.members[found.local_index])
  if self.frame != nil and self.frame.ns != nil and self.frame.ns.members.hasKey(key):
    return (true, self.frame.ns.members[key])
  return (false, NIL)

proc import_items(self: ptr VirtualMachine, source_ns: Namespace, items: seq[ImportItem]) =
  if source_ns == nil or self.frame == nil or self.frame.ns == nil:
    return

  for item in items:
    if item.name == "*":
      for key, value in source_ns.members:
        if value != NIL and not skip_wildcard_import_key(key):
          self.frame.ns.members[key] = value
    else:
      let value = resolve_import_value(source_ns, item.name)
      let import_name = if item.alias != "":
        item.alias
      else:
        let parts = item.name.split("/")
        parts[^1]
      self.frame.ns.members[import_name.to_key()] = value

import ./vm/arithmetic
import ./vm/generator
import ./vm/thread

# Forward declarations needed by vm/async
proc exec*(self: ptr VirtualMachine): Value
proc exec_function*(self: ptr VirtualMachine, fn: Value, args: seq[Value]): Value
proc exec_method*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value]): Value
proc exec_method_kw*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], kw_pairs: seq[(Key, Value)]): Value
proc exec_method_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], caller_context: Frame): Value
proc exec_method_kw_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value], kw_pairs: seq[(Key, Value)], caller_context: Frame): Value
proc execute_future_callbacks*(self: ptr VirtualMachine, future_obj: FutureObj)
proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string
proc spawn_thread(code: ptr Gene, return_value: bool): Value
proc poll_event_loop*(self: ptr VirtualMachine)
proc run_module_init*(self: ptr VirtualMachine, module_ns: Namespace): tuple[ran: bool, value: Value]

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

import ./vm/async

when not defined(noExtensions):
  import ./vm/extension
proc dispatch_exception(self: ptr VirtualMachine, value: Value, inst: var ptr Instruction): bool

# Template to get the class of a value for unified method calls
template get_value_class(val: Value): Class =
  case val.kind:
  of VkCustom:
    types.ref(val).custom_class
  of VkInstance:
    instance_class(val)
  of VkNil:
    types.ref(App.app.nil_class).class
  of VkBool:
    types.ref(App.app.bool_class).class
  of VkInt:
    types.ref(App.app.int_class).class
  of VkFloat:
    types.ref(App.app.float_class).class
  of VkChar:
    types.ref(App.app.char_class).class
  of VkString:
    types.ref(App.app.string_class).class
  of VkSymbol:
    types.ref(App.app.symbol_class).class
  of VkComplexSymbol:
    types.ref(App.app.complex_symbol_class).class
  of VkArray:
    types.ref(App.app.array_class).class
  of VkMap:
    types.ref(App.app.map_class).class
  of VkGene:
    types.ref(App.app.gene_class).class
  of VkDate:
    types.ref(App.app.date_class).class
  of VkDateTime:
    types.ref(App.app.datetime_class).class
  of VkSet:
    types.ref(App.app.set_class).class
  of VkSelector:
    types.ref(App.app.selector_class).class
  of VkRegex:
    types.ref(App.app.regex_class).class
  of VkFuture:
    types.ref(App.app.future_class).class
  of VkGenerator:
    types.ref(App.app.generator_class).class
  of VkThread:
    types.ref(THREAD_CLASS_VALUE).class
  of VkThreadMessage:
    types.ref(THREAD_MESSAGE_CLASS_VALUE).class
  of VkClass:
    types.ref(App.app.class_class).class
  of VkAspect:
    types.ref(App.app.aspect_class).class
  else:
    types.ref(App.app.object_class).class

proc enter_function(self: ptr VirtualMachine, name: string) {.inline.} =
  if self.profiling:
    let start_time = cpuTime()
    self.profile_stack.add((name, start_time))
    
proc exit_function(self: ptr VirtualMachine) {.inline.} =
  if self.profiling and self.profile_stack.len > 0:
    let (fn_name, start_time) = self.profile_stack[^1]
    self.profile_stack.del(self.profile_stack.len - 1)
    
    let end_time = cpuTime()
    let elapsed = end_time - start_time
    
    # Update or create profile entry
    if fn_name notin self.profile_data:
      self.profile_data[fn_name] = FunctionProfile(
        name: fn_name,
        call_count: 0,
        total_time: 0.0,
        self_time: 0.0,
        min_time: elapsed,
        max_time: elapsed
      )
    
    var profile = self.profile_data[fn_name]
    profile.call_count.inc()
    profile.total_time += elapsed
    
    # Update min/max
    if elapsed < profile.min_time:
      profile.min_time = elapsed
    if elapsed > profile.max_time:
      profile.max_time = elapsed
    
    # Calculate self time (subtract child call times)
    for i in countdown(self.profile_stack.len - 1, 0):
      if self.profile_stack[i].name == fn_name:
        break
      # This is a simplification - proper self time calculation is more complex
    profile.self_time = profile.total_time  # For now, just use total

    self.profile_data[fn_name] = profile

proc unwind_scopes_to(self: ptr VirtualMachine, target: Scope) =
  ## Unwind runtime scopes to `target` (inclusive), freeing any child scopes.
  ##
  ## Exception dispatch can jump over IkScopeEnd instructions, so we must restore
  ## the dynamic scope chain to the state that existed when the handler was installed.
  if self.frame.isNil:
    return

  if self.frame.scope == target:
    return

  # Ensure target is reachable from the current scope chain to avoid corrupting state.
  if target != nil:
    var cursor = self.frame.scope
    while cursor != nil and cursor != target:
      cursor = cursor.parent
    if cursor != target:
      raise new_exception(types.Exception, "Exception handler scope mismatch")

  var scope = self.frame.scope
  while scope != nil and scope != target:
    let parent = scope.parent
    scope.free()
    scope = parent

  self.frame.scope = target

proc dispatch_exception(self: ptr VirtualMachine, value: Value, inst: var ptr Instruction): bool =
  ## Shared exception dispatch logic (used by IkThrow).
  var exception_value = value
  self.current_exception = exception_value

  if self.aop_contexts.len > 0:
    let ctx_idx = self.aop_contexts.len - 1
    if self.exception_handlers.len == 0 or self.exception_handlers.len - 1 < self.aop_contexts[ctx_idx].handler_depth:
      self.aop_contexts[ctx_idx].exception_escaped = true

  if self.repl_skip_on_throw:
    self.repl_skip_on_throw = false
  # NOTE: repl_on_error VM flag is used by --repl-on-error command-line option
  # which should only trigger REPL at the command-line error handler level,
  # not during VM exception dispatch. The ^^repl decorator feature for on-throw
  # REPL is not currently implemented.
  # elif self.repl_on_error and not self.repl_active and repl_on_throw_callback != nil:
  #   self.repl_ran = false
  #   self.repl_resume_value = NIL
  #   let repl_thrown = repl_on_throw_callback(self, exception_value)
  #   if self.repl_ran:
  #     if repl_thrown == NIL:
  #       if inst.kind == IkThrow:
  #         let resume_value = self.repl_resume_value
  #         self.repl_resume_value = NIL
  #         self.frame.push(resume_value)
  #       self.current_exception = NIL
  #       let next_pc = self.pc + 1
  #       if next_pc < self.cu.instructions.len:
  #         self.pc = next_pc
  #       else:
  #         self.pc = self.cu.instructions.len - 1
  #       inst = self.cu.instructions[self.pc].addr
  #       return true
  #     exception_value = repl_thrown
  #     self.current_exception = exception_value

  let handler_base = if self.exec_handler_base_stack.len > 0: self.exec_handler_base_stack[^1] else: 0
  if self.exception_handlers.len > handler_base:
    let handler = self.exception_handlers[^1]

    if handler.catch_pc == CATCH_PC_ASYNC_BLOCK:
      discard self.exception_handlers.pop()

      let future_val = new_future_value()
      let future_obj = future_val.ref.future
      future_obj.fail(exception_value)
      self.frame.push(future_val)

      while self.pc < self.cu.instructions.len and self.cu.instructions[self.pc].kind != IkAsyncEnd:
        self.pc.inc()
      if self.pc < self.cu.instructions.len:
        self.pc.inc()
        inst = self.cu.instructions[self.pc].addr
      return true

    elif handler.catch_pc == CATCH_PC_ASYNC_FUNCTION:
      discard self.exception_handlers.pop()

      let future_val = new_future_value()
      let future_obj = future_val.ref.future
      future_obj.fail(exception_value)

      if self.frame.caller_frame != nil:
        self.cu = self.frame.caller_address.cu
        self.pc = self.frame.caller_address.pc
        inst = self.cu.instructions[self.pc].addr
        self.frame.update(self.frame.caller_frame)
        self.frame.ref_count.dec()
        self.frame.push(future_val)
      return true

    else:
      # Unwind frames back to the one that installed the handler
      if self.frame != handler.frame:
        var f = self.frame
        while f != nil and f != handler.frame:
          let caller = f.caller_frame
          # Mirror normal return cleanup
          if caller != nil:
            f.ref_count.dec()
          f = caller
        if f == nil:
          raise new_exception(types.Exception, "Exception handler frame mismatch")
        self.frame = f

      # Restore scope chain to the state at try-start.
      self.unwind_scopes_to(handler.scope)

      self.cu = handler.cu
      self.pc = handler.catch_pc
      if self.pc < self.cu.instructions.len:
        inst = self.cu.instructions[self.pc].addr
        return true
      else:
        raise new_exception(types.Exception, "Invalid catch PC: " & $self.pc)

  else:
    raise new_exception(types.Exception, self.format_runtime_exception(exception_value))

proc pop_frame_exception_handlers(self: ptr VirtualMachine, frame: Frame) {.inline.} =
  ## Remove any exception handlers tied to a frame that's being returned from.
  if frame == nil:
    return
  while self.exception_handlers.len > 0 and self.exception_handlers[^1].frame == frame:
    discard self.exception_handlers.pop()

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

proc print_profile*(self: ptr VirtualMachine) =
  if not self.profiling or self.profile_data.len == 0:
    echo "No profiling data available"
    return
  
  echo "\n=== Function Profile Report ==="
  echo "Function                       Calls      Total(ms)       Avg(μs)     Min(μs)     Max(μs)"
  echo repeat('-', 94)
  
  # Sort by total time descending
  var profiles: seq[FunctionProfile] = @[]
  for name, profile in self.profile_data:
    profiles.add(profile)
  
  profiles.sort do (a, b: FunctionProfile) -> int:
    if a.total_time > b.total_time: -1
    elif a.total_time < b.total_time: 1
    else: 0
  
  for profile in profiles:
    let total_ms = profile.total_time * 1000.0
    let avg_us = if profile.call_count > 0: (profile.total_time * 1_000_000.0) / profile.call_count.float else: 0.0
    let min_us = profile.min_time * 1_000_000.0
    let max_us = profile.max_time * 1_000_000.0
    
    # Use manual formatting for now
    var name_str = profile.name
    if name_str.len > 30:
      name_str = name_str[0..26] & "..."
    while name_str.len < 30:
      name_str = name_str & " "
    
    echo fmt"{name_str} {profile.call_count:10} {total_ms:12.3f} {avg_us:12.3f} {min_us:10.3f} {max_us:10.3f}"
  
  echo "\nTotal functions profiled: ", self.profile_data.len

proc print_instruction_profile*(self: ptr VirtualMachine) =
  if not self.instruction_profiling:
    echo "No instruction profiling data available"
    return
  
  echo "\n=== Instruction Profile Report ==="
  echo "Instruction              Count        Total(ms)     Avg(ns)    Min(ns)    Max(ns)     %Time"
  echo repeat('-', 94)
  
  # Calculate total time
  var total_time = 0.0
  for kind in InstructionKind:
    if self.instruction_profile[kind].count > 0:
      total_time += self.instruction_profile[kind].total_time
  
  # Collect and sort instructions by total time
  type InstructionStat = tuple[kind: InstructionKind, profile: InstructionProfile]
  var stats: seq[InstructionStat] = @[]
  for kind in InstructionKind:
    if self.instruction_profile[kind].count > 0:
      stats.add((kind, self.instruction_profile[kind]))
  
  stats.sort do (a, b: InstructionStat) -> int:
    if a.profile.total_time > b.profile.total_time: -1
    elif a.profile.total_time < b.profile.total_time: 1
    else: 0
  
  # Print top instructions
  for stat in stats:
    let kind = stat.kind
    let profile = stat.profile
    let total_ms = profile.total_time * 1000.0
    let avg_ns = if profile.count > 0: (profile.total_time * 1_000_000_000.0) / profile.count.float else: 0.0
    let min_ns = profile.min_time * 1_000_000_000.0
    let max_ns = profile.max_time * 1_000_000_000.0
    let percent = if total_time > 0: (profile.total_time / total_time) * 100.0 else: 0.0
    
    # Format instruction name
    var name_str = $kind
    if name_str.startswith("Ik"):
      name_str = name_str[2..^1]  # Remove "Ik" prefix
    if name_str.len > 24:
      name_str = name_str[0..20] & "..."
    while name_str.len < 24:
      name_str = name_str & " "
    
    echo fmt"{name_str} {profile.count:12} {total_ms:12.3f} {avg_ns:10.1f} {min_ns:9.1f} {max_ns:9.1f} {percent:8.2f}%"
  
  echo fmt"Total time: {total_time * 1000.0:.3f} ms"
  echo "Instructions profiled: ", stats.len

#################### Unified Callable System ####################

proc pop_call_base_info(vm: ptr VirtualMachine, expected: int = -1): tuple[hasBase: bool, base: uint16, count: int] {.inline.} =
  ## Retrieve call base metadata if present, otherwise fall back to expected count.
  if vm.frame.call_bases.is_empty():
    result.hasBase = false
    result.base = 0
    result.count = expected
  else:
    result.hasBase = true
    result.base = vm.frame.call_bases.pop()
    result.count = vm.frame.call_arg_count_from(result.base)
    when not defined(release):
      if expected >= 0 and result.count != expected:
        discard

proc unified_call_dispatch*(vm: ptr VirtualMachine, callable: Callable,
                           args: seq[Value], self_value: Value = NIL,
                           is_tail_call: bool = false): Value =
  ## Unified call dispatcher that handles all callable types through a single interface
  let flags = callable.flags

  # Argument evaluation optimization
  let processed_args =
    if CfEvaluateArgs in flags:
      # For now, use standard evaluation - can optimize later
      args
    else:
      args  # No evaluation for macros

  # Add self parameter for methods
  let final_args =
    if CfIsMethod in flags:
      if self_value == NIL:
        not_allowed("Method call requires a receiver")
      @[self_value] & processed_args
    else:
      processed_args

  # Dispatch based on callable kind with optimized paths
  case callable.kind:
  of CkNativeFunction, CkNativeMethod:
    # Use new native function signature with helper
    return call_native_fn(callable.native_fn, vm, final_args)

  of CkFunction, CkMethod:
    # Handle Gene functions and methods
    let f = callable.fn
    if f.body_compiled == nil:
      f.compile()

    # Tail call optimization: reuse current frame if this is a tail call
    if is_tail_call and is_function_like(vm.frame.kind):
      # Reuse current frame for tail call optimization
      var scope: Scope
      if f.matcher.is_empty():
        scope = f.parent_scope
        if scope != nil:
          scope.ref_count.inc()
      else:
        scope = new_scope(f.scope_tracker, f.parent_scope)

      # Update current frame for tail call
      vm.frame.scope = scope
      vm.frame.ns = f.ns

      # OPTIMIZATION: Direct argument processing for tail calls
      if not f.matcher.is_empty():
        if final_args.len == 0:
          process_args_zero(f.matcher, vm.frame.scope)
        elif final_args.len == 1:
          process_args_one(f.matcher, final_args[0], vm.frame.scope)
        else:
          process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](final_args[0].addr), final_args.len, false, vm.frame.scope)
      # No need to set vm.frame.args for optimized tail calls

      # Jump to beginning of new function
      vm.cu = f.body_compiled
      vm.pc = 0
      return vm.exec()
    else:
      # Create new frame for function execution
      var scope: Scope
      if f.matcher.is_empty():
        scope = f.parent_scope
        if scope != nil:
          scope.ref_count.inc()
      else:
        scope = new_scope(f.scope_tracker, f.parent_scope)

      var new_frame = new_frame()
      new_frame.kind = FkFunction
      let r = new_ref(VkFunction)
      r.fn = callable.fn
      new_frame.target = r.to_ref_value()
      new_frame.scope = scope
      new_frame.caller_frame = vm.frame
      new_frame.caller_address = Address(cu: vm.cu, pc: vm.pc + 1)
      new_frame.ns = f.ns

      # OPTIMIZATION: Direct argument processing without Gene objects
      if not f.matcher.is_empty():
        if final_args.len == 0:
          process_args_zero(f.matcher, new_frame.scope)
        elif final_args.len == 1:
          process_args_one(f.matcher, final_args[0], new_frame.scope)
        else:
          process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](final_args[0].addr), final_args.len, false, new_frame.scope)
      # No need to set new_frame.args for optimized argument processing

      # Switch to new frame and execute
      vm.frame = new_frame
      vm.cu = f.body_compiled
      vm.pc = 0
      return vm.exec()

  of CkBlock:
    # Handle blocks - similar to functions but with captured scope
    let blk = callable.block_fn
    if blk.body_compiled == nil:
      blk.compile()

    var scope: Scope
    if blk.matcher.is_empty():
      scope = blk.frame.scope  # Use captured scope
    else:
      scope = new_scope(blk.scope_tracker, blk.frame.scope)

    var new_frame = new_frame()
    new_frame.kind = FkBlock
    let r3 = new_ref(VkBlock)
    r3.block = callable.block_fn
    new_frame.target = r3.to_ref_value()
    new_frame.scope = scope
    new_frame.caller_frame = vm.frame
    new_frame.caller_address = Address(cu: vm.cu, pc: vm.pc + 1)
    new_frame.ns = blk.ns

    # Create args Gene for argument processing
    var args_gene = new_gene_value()
    for arg in final_args:
      args_gene.gene.children.add(arg)
    new_frame.args = args_gene

    # Process arguments if matcher exists
    if not blk.matcher.is_empty():
      process_args(blk.matcher, args_gene, new_frame.scope)

    # Switch to new frame and execute
    vm.frame = new_frame
    vm.cu = blk.body_compiled
    vm.pc = 0
    return vm.exec()

proc value_to_callable*(value: Value): Callable =
  ## Convert a Value to a Callable for unified dispatch
  case value.kind:
  of VkFunction:
    return value.ref.fn.to_callable()
  of VkNativeFn:
    return to_callable(value.ref.native_fn)
  of VkBlock:
    return value.ref.block.to_callable()
  of VkBoundMethod:
    # Convert bound method to appropriate callable
    let bm = value.ref.bound_method
    let method_callable = value_to_callable(bm.`method`.callable)
    # Modify flags to indicate it's a method
    method_callable.flags.incl(CfIsMethod)
    method_callable.flags.incl(CfNeedsSelf)
    return method_callable
  of VkNativeMethod:
    # Handle native methods
    return to_callable(value.ref.native_method, "", 0)
  else:
    not_allowed("Cannot convert " & $value.kind & " to Callable")

proc render_template(self: ptr VirtualMachine, tpl: Value): Value =
  # Render a template by recursively processing quote/unquote values
  case tpl.kind:
    of VkQuote:
      # A quoted value - render its contents
      return self.render_template(tpl.ref.quote)
    
    of VkUnquote:
      # An unquoted value - evaluate it in the current context
      let expr = tpl.ref.unquote
      let discard_result = tpl.ref.unquote_discard
      
      # For now, evaluate simple cases directly without creating new frames
      # TODO: Implement full expression evaluation
      var r: Value = NIL
      
      case expr.kind:
        of VkSymbol:
          # Look up the symbol in the current scope using the scope tracker
          let key = expr.str.to_key()
          
          # Use the scope tracker to find the variable
          let var_index = self.frame.scope.tracker.locate(key)
          
          if var_index.local_index >= 0:
            # Found in scope - navigate to the correct scope
            var scope = self.frame.scope
            var parent_index = var_index.parent_index
            
            while parent_index > 0 and scope != nil:
              parent_index.dec()
              scope = scope.parent
            
            if scope != nil and var_index.local_index < scope.members.len:
              r = scope.members[var_index.local_index]
            else:
              # Not found, default to symbol
              r = expr
          else:
            # Not in scope, check namespace
            if self.frame.ns.members.hasKey(key):
              r = self.frame.ns.members[key]
            else:
              # Default to the symbol itself
              r = expr
            
        of VkGene:
          # For gene expressions, recursively render the parts
          let gene = expr.gene
          let rendered_type = self.render_template(gene.type)
          
          # Create a new gene with rendered parts
          let new_gene = new_gene(rendered_type)
          
          # Render properties
          for k, v in gene.props:
            new_gene.props[k] = self.render_template(v)
          
          # Render children
          for child in gene.children:
            new_gene.children.add(self.render_template(child))
          
          # For now, return the rendered gene without evaluating
          # TODO: Implement full expression evaluation
          r = new_gene.to_gene_value()
            
        of VkInt, VkFloat, VkBool, VkString, VkChar:
          # Literal values pass through unchanged
          r = expr
        else:
          # For other types, recursively render
          r = self.render_template(expr)
      
      if discard_result:
        # %_ means discard the r
        return NIL
      else:
        return r
    
    of VkGene:
      # Recursively render gene expressions
      let gene = tpl.gene
      let new_gene = new_gene(self.render_template(gene.type))
      
      # Render properties
      for k, v in gene.props:
        new_gene.props[k] = self.render_template(v)
      
      # Render children
      for child in gene.children:
        let rendered = self.render_template(child)
        new_gene.children.add(rendered)
      
      return new_gene.to_gene_value()
    
    of VkArray:
      # Recursively render array elements
      var new_arr = new_array_value()
      for item in array_data(tpl):
        let rendered = self.render_template(item)
        # Skip NIL values that come from %_ (unquote discard)
        if rendered.kind == VkNil and item.kind == VkUnquote and item.ref.unquote_discard:
          continue
        else:
          array_data(new_arr).add(rendered)
      return new_arr
    
    of VkMap:
      # Recursively render map values
      let new_map = new_map_value()
      for k, v in map_data(tpl):
        map_data(new_map)[k] = self.render_template(v)
      return new_map
    
    else:
      # Other values pass through unchanged
      return tpl

proc call_instance_method(self: ptr VirtualMachine, instance: Value, method_name: string,
                          args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
  ## Helper to forward instance calls to 'call' method
  ## Returns true if method was found and call was initiated (via continue), false otherwise
  ## When returns true, the VM state has been set up for the call and caller should continue execution
  let call_method_key = method_name.to_key()
  let class = instance.get_object_class()

  if class.is_nil or not class.methods.hasKey(call_method_key):
    return false

  let meth = class.methods[call_method_key]
  case meth.callable.kind:
  of VkFunction:
    let f = meth.callable.ref.fn
    if f.body_compiled == nil:
      f.compile()

    var scope: Scope
    if f.matcher.is_empty():
      scope = f.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(f.scope_tracker, f.parent_scope)
      # Manually set self and args in scope
      var all_args = newSeq[Value](args.len + 1)
      all_args[0] = instance
      for i in 0..<args.len:
        all_args[i + 1] = args[i]

      # Process arguments using the direct method
      if all_args.len > 0:
        let args_ptr = cast[ptr UncheckedArray[Value]](all_args[0].addr)
        if kw_pairs.len > 0:
          process_args_direct_kw(f.matcher, args_ptr, all_args.len, kw_pairs, scope)
        else:
          process_args_direct(f.matcher, args_ptr, all_args.len, false, scope)

    var new_frame = new_frame()
    new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
    new_frame.target = meth.callable
    new_frame.scope = scope
    if f.is_macro_like:
      new_frame.caller_context = self.frame
    let args_gene = new_gene_value()
    args_gene.gene.children.add(instance)
    for arg in args:
      args_gene.gene.children.add(arg)
    new_frame.args = args_gene
    new_frame.caller_frame = self.frame
    self.frame.ref_count.inc()
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
    new_frame.ns = f.ns

    if f.async:
      self.exception_handlers.add(ExceptionHandler(
        catch_pc: CATCH_PC_ASYNC_FUNCTION,
        finally_pc: -1,
        frame: self.frame,
        scope: self.frame.scope,
        cu: self.cu,
        saved_value: NIL,
        has_saved_value: false,
        in_finally: false
      ))

    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    return true

  of VkNativeFn:
    # Call native 'call' method with instance as first argument
    let has_kw = kw_pairs.len > 0
    var kw_map = new_map_value()
    if has_kw:
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v

    let offset = if has_kw: 1 else: 0
    var all_args = newSeq[Value](args.len + 1 + offset)
    if has_kw:
      all_args[0] = kw_map
    all_args[offset] = instance
    for i in 0..<args.len:
      all_args[i + offset + 1] = args[i]
    let result = call_native_fn(meth.callable.ref.native_fn, self, all_args, has_kw)
    self.frame.push(result)
    return true

  else:
    not_allowed("call method must be a function or native function")
    return false

proc call_super_method_resolved(self: ptr VirtualMachine, parent_class: Class, instance: Value, method_name: string, args: openArray[Value], expect_macro: bool, kw_pairs: seq[(Key, Value)] = @[]): bool =
  ## Invoke a superclass method without allocating a proxy.
  if parent_class == nil:
    not_allowed("No parent class available for super")
  if instance.kind notin {VkInstance, VkCustom}:
    not_allowed("super requires an instance context")

  let method_key = method_name.to_key()
  var class = parent_class
  var meth: Method = nil

  while class != nil and meth.is_nil:
    if class.methods.hasKey(method_key):
      meth = class.methods[method_key]
    else:
      class = class.parent

  if meth.is_nil:
    not_allowed("Method '" & method_name & "' not found in super class hierarchy")

  case meth.callable.kind:
  of VkFunction:
    let f = meth.callable.ref.fn
    if expect_macro and not f.is_macro_like:
      not_allowed("Superclass method '" & method_name & "' is not macro-like")
    if (not expect_macro) and f.is_macro_like:
      not_allowed("Superclass method '" & method_name & "' is macro-like; use .m!")

    if f.body_compiled == nil:
      f.compile()

    var scope: Scope
    if f.matcher.is_empty():
      scope = f.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(f.scope_tracker, f.parent_scope)
      var all_args = newSeq[Value](args.len + 1)
      all_args[0] = instance
      for i in 0..<args.len:
        all_args[i + 1] = args[i]
      if all_args.len > 0:
        let args_ptr = cast[ptr UncheckedArray[Value]](all_args[0].addr)
        if kw_pairs.len > 0:
          process_args_direct_kw(f.matcher, args_ptr, all_args.len, kw_pairs, scope)
        else:
          process_args_direct(f.matcher, args_ptr, all_args.len, false, scope)

    var new_frame = new_frame()
    new_frame.kind = if expect_macro: FkMacroMethod else: FkMethod
    new_frame.target = meth.callable
    new_frame.scope = scope
    if expect_macro:
      new_frame.caller_context = self.frame
    let args_gene = new_gene_value()
    args_gene.gene.children.add(instance)
    for arg in args:
      args_gene.gene.children.add(arg)
    new_frame.args = args_gene
    new_frame.caller_frame = self.frame
    self.frame.ref_count.inc()
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
    new_frame.ns = f.ns

    if f.async:
      self.exception_handlers.add(ExceptionHandler(
        catch_pc: CATCH_PC_ASYNC_FUNCTION,
        finally_pc: -1,
        frame: self.frame,
        scope: self.frame.scope,
        cu: self.cu,
        saved_value: NIL,
        has_saved_value: false,
        in_finally: false
      ))

    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    return true

  of VkNativeFn:
    if expect_macro:
      not_allowed("Superclass method '" & method_name & "' is not macro-like")
    let has_kw = kw_pairs.len > 0
    let offset = if has_kw: 1 else: 0
    var all_args = newSeq[Value](args.len + 1 + offset)
    if has_kw:
      var kw_map = new_map_value()
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v
      all_args[0] = kw_map
    all_args[offset] = instance
    for i in 0..<args.len:
      all_args[i + offset + 1] = args[i]
    let result = call_native_fn(meth.callable.ref.native_fn, self, all_args, has_kw)
    self.frame.push(result)
    return true

  else:
    not_allowed("Super method must be a function or native function")
    return false

proc call_super_method(self: ptr VirtualMachine, super_value: Value, method_name: string, args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
  ## Legacy helper that accepts a VkSuper proxy.
  if super_value.kind != VkSuper:
    return false
  let super_ref = super_value.ref
  return self.call_super_method_resolved(super_ref.super_class, super_ref.super_instance, method_name, args, method_name.ends_with("!"), kw_pairs)

proc call_value_method(self: ptr VirtualMachine, value: Value, method_name: string,
                       args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
  ## Helper for calling native/class methods on non-instance values (strings, selectors, etc.)
  let value_class = get_value_class(value)
  if value_class == nil:
    when not defined(release):
      if self.trace:
        echo "call_value_method: no class for ", value.kind, " method ", method_name
    return false

  let meth = value_class.get_method(method_name)
  if meth == nil:
    when not defined(release):
      if self.trace:
        echo "call_value_method: method ", method_name, " missing on ", value.kind
    return false
  case meth.callable.kind:
  of VkFunction:
    let f = meth.callable.ref.fn
    if f.body_compiled == nil:
      f.compile()

    var scope: Scope
    if f.matcher.is_empty():
      scope = f.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(f.scope_tracker, f.parent_scope)
      # Build argument list including self and positional args
      var all_args = newSeq[Value](args.len + 1)
      all_args[0] = value
      for i in 0..<args.len:
        all_args[i + 1] = args[i]

      if all_args.len > 0:
        let args_ptr = cast[ptr UncheckedArray[Value]](all_args[0].addr)
        if kw_pairs.len > 0:
          process_args_direct_kw(f.matcher, args_ptr, all_args.len, kw_pairs, scope)
        else:
          process_args_direct(f.matcher, args_ptr, all_args.len, false, scope)

    var new_frame = new_frame()
    new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
    new_frame.target = meth.callable
    new_frame.scope = scope
    let args_gene = new_gene_value()
    args_gene.gene.children.add(value)
    for arg in args:
      args_gene.gene.children.add(arg)
    new_frame.args = args_gene
    new_frame.caller_frame = self.frame
    self.frame.ref_count.inc()
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
    new_frame.ns = f.ns

    if f.async:
      self.exception_handlers.add(ExceptionHandler(
        catch_pc: CATCH_PC_ASYNC_FUNCTION,
        finally_pc: -1,
        frame: self.frame,
        scope: self.frame.scope,
        cu: self.cu,
        saved_value: NIL,
        has_saved_value: false,
        in_finally: false
      ))

    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    return true

  of VkNativeFn:
    let has_kw = kw_pairs.len > 0
    var kw_map = new_map_value()
    if has_kw:
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v

    let offset = if has_kw: 1 else: 0
    var all_args = newSeq[Value](args.len + 1 + offset)
    if has_kw:
      all_args[0] = kw_map
    all_args[offset] = value
    for i in 0..<args.len:
      all_args[i + offset + 1] = args[i]
    let result = call_native_fn(meth.callable.ref.native_fn, self, all_args, has_kw)
    self.frame.push(result)
    return true

  else:
    not_allowed("Method must be a function or native function")
    return false

proc call_interception_original(self: ptr VirtualMachine, original: Value, instance: Value,
                                args: seq[Value], kw_pairs: seq[(Key, Value)]): Value =
  case original.kind
  of VkFunction:
    if kw_pairs.len > 0:
      return self.exec_method_kw(original, instance, args, kw_pairs)
    return self.exec_method(original, instance, args)
  of VkNativeFn:
    let has_kw = kw_pairs.len > 0
    let offset = if has_kw: 1 else: 0
    var call_args = newSeq[Value](args.len + 1 + offset)
    if has_kw:
      var kw_map = new_map_value()
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v
      call_args[0] = kw_map
    call_args[offset] = instance
    for i, arg in args:
      call_args[i + offset + 1] = arg
    return call_native_fn(original.ref.native_fn, self, call_args, has_kw)
  of VkInterception:
    return self.call_interception_original(original.ref.interception.original, instance, args, kw_pairs)
  else:
    not_allowed("Intercepted callable must be a function or native function")

proc run_intercepted_method(self: ptr VirtualMachine, interception: Interception, instance: Value,
                            args: seq[Value], kw_pairs: seq[(Key, Value)] = @[]): Value =
  let aspect_val = interception.aspect
  if aspect_val.kind != VkAspect:
    not_allowed("Aspect interception requires a VkAspect")
  let aspect = aspect_val.ref.aspect
  let param_name = interception.param_name
  let wrapped_method = Method(
    class: nil,
    name: param_name,
    callable: interception.original,
    is_macro: false
  )
  let wrapped_ref = new_ref(VkBoundMethod)
  wrapped_ref.bound_method = BoundMethod(
    self: instance,
    `method`: wrapped_method
  )
  let wrapped_value = wrapped_ref.to_ref_value()
  let ctx = AopContext(
    wrapped: interception.original,
    instance: instance,
    args: args,
    kw_pairs: kw_pairs,
    in_around: false,
    caller_context: self.frame,
    handler_depth: self.exception_handlers.len,
    exception_escaped: false
  )
  self.aop_contexts.add(ctx)
  defer:
    discard self.aop_contexts.pop()

  proc matcher_positional_bounds(matcher: RootMatcher): tuple[minc: int, maxc: int, has_splat: bool] =
    var minc = 0
    var maxc = 0
    var has_splat = false
    for param in matcher.children:
      if param.kind == MatchProp or param.is_prop:
        continue
      if param.is_splat:
        has_splat = true
      else:
        maxc += 1
        if param.required():
          minc += 1
    (minc, maxc, has_splat)

  proc advice_accepts_result(advice_fn: Value, base_count: int): bool =
    if advice_fn.kind != VkFunction:
      return true
    let bounds = matcher_positional_bounds(advice_fn.ref.fn.matcher)
    if bounds.has_splat:
      return true
    let desired = base_count + 1
    desired <= bounds.maxc

  proc call_advice(advice_fn: Value, instance: Value, args: seq[Value]): Value =
    case advice_fn.kind
    of VkFunction:
      return self.exec_method(advice_fn, instance, args)
    of VkNativeFn:
      var call_args = newSeq[Value](args.len + 1)
      call_args[0] = instance
      for i, arg in args:
        call_args[i + 1] = arg
      return call_native_fn(advice_fn.ref.native_fn, self, call_args, false)
    else:
      not_allowed("Advice callable must be a function or native function")
      return NIL

  if aspect.enabled:
    if aspect.before_filter_advices.hasKey(param_name):
      for advice_fn in aspect.before_filter_advices[param_name]:
        let ok = call_advice(advice_fn, instance, args)
        if not ok.to_bool():
          return NIL

    if aspect.before_advices.hasKey(param_name):
      for advice_fn in aspect.before_advices[param_name]:
        discard call_advice(advice_fn, instance, args)
    if aspect.invariant_advices.hasKey(param_name):
      for advice_fn in aspect.invariant_advices[param_name]:
        discard call_advice(advice_fn, instance, args)
    if self.aop_contexts[^1].exception_escaped:
      return NIL

  var result: Value
  if aspect.enabled and aspect.around_advices.hasKey(param_name):
    let around_fn = aspect.around_advices[param_name]
    let ctx_idx = self.aop_contexts.len - 1
    self.aop_contexts[ctx_idx].in_around = true
    let around_args = args & @[wrapped_value]
    result = call_advice(around_fn, instance, around_args)
    self.aop_contexts[ctx_idx].in_around = false
  else:
    result = self.call_interception_original(interception.original, instance, args, kw_pairs)

  let exception_escaped = self.aop_contexts[^1].exception_escaped
  if not exception_escaped and aspect.enabled and aspect.invariant_advices.hasKey(param_name):
    for advice_fn in aspect.invariant_advices[param_name]:
      discard call_advice(advice_fn, instance, args)

  if not exception_escaped and aspect.enabled and aspect.after_advices.hasKey(param_name):
    for advice_fn in aspect.after_advices[param_name]:
      var after_args = args
      if advice_accepts_result(advice_fn.callable, args.len + 1):
        after_args = args & @[result]
      let advice_result = call_advice(advice_fn.callable, instance, after_args)
      if advice_fn.replace_result:
        result = advice_result

  result

proc call_bound_method(self: ptr VirtualMachine, target: Value, args: seq[Value],
                       kw_pairs: seq[(Key, Value)] = @[]): Value =
  let bm = target.ref.bound_method
  let callable = bm.`method`.callable
  var caller_ctx = self.frame
  if callable.kind == VkFunction and callable.ref.fn.is_macro_like and self.aop_contexts.len > 0:
    let ctx = self.aop_contexts[^1]
    if ctx.in_around and ctx.caller_context != nil and
       same_value_identity(bm.self, ctx.instance) and
       same_value_identity(callable, ctx.wrapped):
      caller_ctx = ctx.caller_context
  case callable.kind
  of VkFunction:
    if kw_pairs.len > 0:
      return self.exec_method_kw_impl(callable, bm.self, args, kw_pairs, caller_ctx)
    return self.exec_method_impl(callable, bm.self, args, caller_ctx)
  of VkNativeFn:
    let has_kw = kw_pairs.len > 0
    let offset = if has_kw: 1 else: 0
    var call_args = newSeq[Value](args.len + 1 + offset)
    if has_kw:
      var kw_map = new_map_value()
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v
      call_args[0] = kw_map
    call_args[offset] = bm.self
    for i, arg in args:
      call_args[i + offset + 1] = arg
    return call_native_fn(callable.ref.native_fn, self, call_args, has_kw)
  of VkNativeMethod:
    let has_kw = kw_pairs.len > 0
    let offset = if has_kw: 1 else: 0
    var call_args = newSeq[Value](args.len + 1 + offset)
    if has_kw:
      var kw_map = new_map_value()
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v
      call_args[0] = kw_map
    call_args[offset] = bm.self
    for i, arg in args:
      call_args[i + offset + 1] = arg
    return call_native_fn(callable.ref.native_method, self, call_args, has_kw)
  of VkInterception:
    return self.run_intercepted_method(callable.ref.interception, bm.self, args, kw_pairs)
  else:
    not_allowed("Bound method must wrap a function or native function")

proc current_self_value(frame: Frame): Value =
  if frame == nil:
    return NIL
  if frame.args.kind == VkGene and frame.args.gene.children.len > 0:
    return frame.args.gene.children[0]
  if frame.scope != nil and frame.target.kind == VkFunction:
    let tracker = frame.target.ref.fn.scope_tracker
    let self_idx = tracker.mappings.get_or_default("self".to_key(), -1)
    if self_idx >= 0 and self_idx < frame.scope.members.len:
      return frame.scope.members[self_idx]
  return NIL

proc find_method_class(instance: Value, callable: Value): Class =
  var cls = instance.get_object_class()
  while cls != nil:
    if not cls.constructor.is_nil and same_value_identity(cls.constructor, callable):
      return cls
    if cls.methods.len > 0:
      for _, m in cls.methods:
        if same_value_identity(m.callable, callable):
          return cls
    cls = cls.parent
  return nil

proc resolve_current_instance_and_parent(self: ptr VirtualMachine): tuple[instance: Value, parent_class: Class] =
  ## Retrieve the current instance and parent class for super calls.
  let instance = current_self_value(self.frame)
  if instance.kind notin {VkInstance, VkCustom}:
    when not defined(release):
      echo "DEBUG super resolve: instance.kind=", instance.kind, " args kind=", self.frame.args.kind
      if self.frame.args.kind == VkGene:
        echo "DEBUG super resolve: args children len=", self.frame.args.gene.children.len
    not_allowed("super requires an instance context")

  let current_class = find_method_class(instance, self.frame.target)
  if current_class.is_nil or current_class.parent.is_nil:
    not_allowed("No parent class available for super")

  (instance, current_class.parent)

proc call_super_constructor(self: ptr VirtualMachine, parent_class: Class, instance: Value, args: openArray[Value], expect_macro: bool): bool =
  ## Invoke a superclass constructor without allocation.
  if parent_class == nil:
    not_allowed("No parent class available for super")
  if instance.kind notin {VkInstance, VkCustom}:
    not_allowed("super requires an instance context")

  if parent_class.has_macro_constructor and not expect_macro:
    not_allowed("Superclass defines ctor!, use super .ctor! instead of super .ctor")
  if (not parent_class.has_macro_constructor) and expect_macro:
    not_allowed("Superclass defines ctor, use super .ctor instead of super .ctor!")

  let ctor = parent_class.get_constructor()
  if ctor.is_nil:
    not_allowed("Superclass has no constructor")

  case ctor.kind:
  of VkFunction:
    let f = ctor.ref.fn
    if expect_macro and not f.is_macro_like:
      not_allowed("Superclass constructor is not macro-like")
    if (not expect_macro) and f.is_macro_like:
      not_allowed("Superclass constructor is macro-like; use super .ctor!")

    if f.body_compiled == nil:
      f.compile()

    var scope: Scope
    if f.matcher.is_empty():
      scope = f.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(f.scope_tracker, f.parent_scope)
      if args.len > 0:
        var user_args = newSeq[Value](args.len)
        for i in 0..<args.len:
          user_args[i] = args[i]
        process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](user_args[0].addr), user_args.len, false, scope)
      assign_property_params(f.matcher, scope, instance)

    var new_frame = new_frame()
    new_frame.kind = if expect_macro: FkMacroMethod else: FkMethod
    new_frame.target = ctor
    new_frame.scope = scope
    new_frame.caller_frame = self.frame
    self.frame.ref_count.inc()
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
    new_frame.ns = f.ns
    if expect_macro:
      new_frame.caller_context = self.frame

    let args_gene = new_gene_value()
    args_gene.gene.children.add(instance)
    for arg in args:
      args_gene.gene.children.add(arg)
    new_frame.args = args_gene

    if f.async:
      self.exception_handlers.add(ExceptionHandler(
        catch_pc: CATCH_PC_ASYNC_FUNCTION,
        finally_pc: -1,
        frame: self.frame,
        scope: self.frame.scope,
        cu: self.cu,
        saved_value: NIL,
        has_saved_value: false,
        in_finally: false
      ))

    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    return true

  of VkNativeFn:
    if expect_macro:
      not_allowed("Superclass constructor is not macro-like")
    let result = call_native_fn(ctor.ref.native_fn, self, args)
    self.frame.push(result)
    return true

  else:
    not_allowed("Superclass constructor must be a function or native function")
    return false

proc ensure_namespace_path(root: Namespace, parts: seq[string], uptoExclusive: int): Namespace =
  ## Ensure that the namespace path exists (creating as needed) and return the target namespace.
  if root.is_nil:
    not_allowed("Cannot define class without an active namespace")
  var current = root
  for i in 0..<uptoExclusive:
    let key = parts[i].to_key()
    var value = if current.members.hasKey(key): current.members[key] else: NIL
    if value == NIL or value.kind != VkNamespace:
      let new_ns = new_namespace(current, parts[i])
      value = new_ns.to_value()
      current.members[key] = value
    current = value.ref.ns
  result = current

proc namespace_from_value(container: Value): Namespace =
  case container.kind
  of VkNamespace:
    result = container.ref.ns
  of VkClass:
    result = container.ref.class.ns
  else:
    not_allowed("Class container must be a namespace or class, got " & $container.kind)

proc exec*(self: ptr VirtualMachine): Value =
  let root_entry = self.exec_depth == 0
  self.exec_depth.inc()
  defer:
    self.exec_depth.dec()
    if self.exec_handler_base_stack.len > 0:
      discard self.exec_handler_base_stack.pop()

  # Reset self.pc for new execution (unless we're resuming a generator)
  # Generators set their PC before calling exec and need to preserve it
  if self.frame == nil or not self.frame.is_generator:
    self.pc = 0
  if self.pc >= self.cu.instructions.len:
    if self.frame != nil and self.frame.is_generator:
      return NOT_FOUND  # Generator is done
    raise new_exception(types.Exception, "Empty compilation unit")
  var inst = self.cu.instructions[self.pc].addr

  when not defined(release):
    var indent = ""

  # Reset exception state only for the outermost exec invocation.
  if root_entry:
    self.current_exception = NIL
    self.exception_handlers.setLen(0)
  self.exec_handler_base_stack.add(self.exception_handlers.len)

  # Hot VM execution loop - disable checks for maximum performance
  {.push boundChecks: off, overflowChecks: off, nilChecks: off, assertions: off.}
  while true:
    # Poll for async/thread events periodically
    self.poll_event_loop()

    when not defined(release):
      if self.trace:
        if inst.kind == IkStart: # This is part of INDENT_LOGIC
          indent &= "  "
        # self.print_stack()
        echo fmt"{indent}{self.pc:04X} {inst[]}"
    
    # Instruction profiling - only declare variables when needed
    when not defined(release):
      var inst_start_time: float64
      var inst_kind_for_profiling: InstructionKind
      if self.instruction_profiling:
        inst_start_time = cpuTime()
        inst_kind_for_profiling = inst.kind  # Save it now, before execution changes anything

    try:
      {.computedGoto.}
      case inst.kind:
      of IkNoop:
        when not defined(release):
          if self.trace:
            echo fmt"{indent}     [Noop at PC {self.pc:04X}, label: {inst.label.int:04X}]"
        discard
      
      of IkData:
        # IkData provides data for the previous instruction
        # It should not be executed directly - the previous instruction should consume it
        when not defined(release):
          if self.trace:
            echo fmt"{indent}     [Data at PC {self.pc:04X}, skipping]"
        discard

      of IkStart:
        when not defined(release):
          if not self.trace: # This is part of INDENT_LOGIC
            indent &= "  "
        # if self.cu.matcher != nil:
        #   self.handle_args(self.cu.matcher, self.frame.args)

      of IkEnd:
        {.push checks: off}
        when not defined(release):
          if indent.len >= 2:
            indent.delete(indent.len-2..indent.len-1)
        # If we have an unhandled exception, raise it now.
        # Suppress re-raising while a catch is still active in an outer frame.
        if self.current_exception != NIL and self.exception_handlers.len == 0:
          raise new_exception(types.Exception, self.format_runtime_exception(self.current_exception))

        # TODO: validate that there is only one value on the stack
        let v = if self.frame.stack_index > 0: self.frame.current() else: NIL
        if self.frame.caller_frame == nil:
          # Before returning, drain any pending futures with callbacks
          # This ensures callbacks execute even if the main code has finished
          self.drain_pending_futures()

          return v
        else:
          let skip_return = self.cu.skip_return
          # Check if we're ending a function called by exec_function (e.g. from $caller_eval)
          let ending_exec_function = self.frame.from_exec_function

          # Check if we're returning from an async function before updating frame
          var result_val = v
          if is_function_like(self.frame.kind) and self.frame.target.kind == VkFunction:
            let f = self.frame.target.ref.fn
            if f.async:
              # Wrap the return value in a future
              let future_val = new_future_value()
              let future_obj = future_val.ref.future
              future_obj.complete(result_val)
              result_val = future_val

          # Profile function exit
          if self.profiling:
            self.exit_function()

          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()  # The frame's ref_count was incremented unnecessarily.
          
          # If we were in exec_function, return without pushing to stack
          if ending_exec_function:
            return result_val
          
          if not skip_return:
            self.frame.push(result_val)

          continue
        {.pop.}

      of IkScopeStart:
        if inst.arg0.kind == VkNil:
          # For GIR files, create a new scope with empty tracker
          let tracker = new_scope_tracker()
          self.frame.scope = new_scope(tracker, self.frame.scope)
          # Scope created with ref_count=1
        elif inst.arg0.kind == VkScopeTracker:
          self.frame.scope = new_scope(inst.arg0.ref.scope_tracker, self.frame.scope)
          # Scope created with ref_count=1
          let tracker = inst.arg0.ref.scope_tracker
          if tracker != nil and self.frame != nil and self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 0:
            let self_key = "self".to_key()
            if tracker.mappings.has_key(self_key):
              let self_idx = tracker.mappings[self_key].int
              if self_idx >= 0:
                while self.frame.scope.members.len <= self_idx:
                  self.frame.scope.members.add(NIL)
                self.frame.scope.members[self_idx] = self.frame.args.gene.children[0]
        else:
          not_allowed("IkScopeStart: expected ScopeTracker or Nil, got " & $inst.arg0.kind)
      of IkScopeEnd:
        # Scope can be nil after exception handling unwinds frames
        if not self.frame.scope.isNil:
          var old_scope = self.frame.scope
          self.frame.scope = self.frame.scope.parent
          # Decrement ref_count and free if no more references
          # This prevents use-after-free bugs with async code that may hold scope references
          # Note: free() will decrement ref_count internally, so we just call it directly
          old_scope.free()
          # Scope will only be deallocated if ref_count reaches 0 inside free()

      of IkVar:
        {.push checks: off.}
        let index = inst.arg0.int64.int
        let value = self.frame.pop()  # Pop the value from the stack
        if self.frame.scope.isNil:
          not_allowed("IkVar: scope is nil")
        let expected = expected_type_for(self.frame.scope.tracker, index)
        if expected.len > 0 and value != NIL:
          validate_type(value, expected, "variable")
        # Ensure the scope has enough space for the index
        while self.frame.scope.members.len <= index:
          self.frame.scope.members.add(NIL)
        self.frame.scope.members[index] = value
        
        # Variables are now stored in scope, not in namespace self
        # This simplifies the design
        
        # Push the value as the result of var
        self.frame.push(value)
        {.pop.}

      of IkVarValue:
        {.push checks: off}
        let index = inst.arg1.int
        let value = inst.arg0
        let expected = expected_type_for(self.frame.scope.tracker, index)
        if expected.len > 0 and value != NIL:
          validate_type(value, expected, "variable")
        # Ensure the scope has enough space for the index
        while self.frame.scope.members.len <= index:
          self.frame.scope.members.add(NIL)
        self.frame.scope.members[index] = value
        
        # Variables are now stored in scope, not in namespace self
        # This simplifies the design
        
        # Also push the value to the stack (like IkVar)
        self.frame.push(value)
        {.pop.}

      of IkVarResolve:
        {.push checks: off}
        # when not defined(release):
        #   if self.trace:
        #     echo fmt"IkVarResolve: arg0={inst.arg0}, arg0.int64.int={inst.arg0.int64.int}, scope.members.len={self.frame.scope.members.len}"
        if self.frame.scope.isNil:
          raise new_exception(types.Exception, "IkVarResolve: scope is nil")
        let index = inst.arg0.int64.int
        if index >= self.frame.scope.members.len:
          raise new_exception(types.Exception, fmt"IkVarResolve: index {index} >= scope.members.len {self.frame.scope.members.len}")
        self.frame.push(self.frame.scope.members[index])
        {.pop.}

      of IkVarResolveInherited:
        var parent_index = inst.arg1.int32
        var scope = self.frame.scope
        while parent_index > 0:
          parent_index.dec()
          if scope.parent == nil:
            raise new_exception(types.Exception, fmt"IkVarResolveInherited: scope.parent is nil at parent_index {parent_index}")
          scope = scope.parent
        if scope == nil:
          raise new_exception(types.Exception, fmt"IkVarResolveInherited: scope is nil after traversing {inst.arg1.int32} parent levels")
        let index = inst.arg0.int64.int
        if index >= scope.members.len:
          raise new_exception(types.Exception, fmt"IkVarResolveInherited: index {index} >= scope.members.len {scope.members.len}")
        {.push checks: off}
        self.frame.push(scope.members[index])
        {.pop.}

      of IkVarAssign:
        {.push checks: off}
        let value = self.frame.current()
        if self.frame.scope == nil:
          raise new_exception(types.Exception, "IkVarAssign: frame.scope is nil")
        let index = inst.arg0.int64.int
        if index >= self.frame.scope.members.len:
          raise new_exception(types.Exception, fmt"IkVarAssign: index {index} >= scope.members.len {self.frame.scope.members.len}")
        let expected = expected_type_for(self.frame.scope.tracker, index)
        if expected.len > 0 and value != NIL:
          validate_type(value, expected, "variable")
        self.frame.scope.members[index] = value
        {.pop.}

      of IkVarAssignInherited:
        {.push checks: off}
        let value = self.frame.current()
        {.pop.}
        var scope = self.frame.scope
        var parent_index = inst.arg1.int32
        while parent_index > 0:
          parent_index.dec()
          scope = scope.parent
        if scope == nil:
          raise new_exception(types.Exception, "IkVarAssignInherited: scope is nil")
        let index = inst.arg0.int64.int
        let expected = expected_type_for(scope.tracker, index)
        if expected.len > 0 and value != NIL:
          validate_type(value, expected, "variable")
        while scope.members.len <= index:
          scope.members.add(NIL)
        {.push checks: off}
        scope.members[index] = value
        {.pop.}

      of IkAssign:
        not_allowed("IkAssign is not implemented")
        # let value = self.frame.current()
        # Find the namespace where the member is defined and assign it there

      of IkRepeatInit:
        {.push checks: off}
        var count_val = self.frame.pop()
        var remaining: int64
        case count_val.kind:
        of VkInt:
          remaining = count_val.int64
        of VkFloat:
          remaining = count_val.float.int64
        else:
          if count_val.to_bool:
            remaining = 1
          else:
            remaining = 0
        when not defined(release):
          if self.trace:
            echo "IkRepeatInit remaining=", remaining
        if remaining <= 0:
          self.pc = inst.arg0.int64.int
          if self.pc < self.cu.instructions.len:
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            break
        else:
          self.frame.push(remaining.to_value())
        {.pop.}

      of IkRepeatDecCheck:
        {.push checks: off}
        var remaining_val = self.frame.pop()
        var remaining: int64
        case remaining_val.kind:
        of VkInt:
          remaining = remaining_val.int64
        of VkFloat:
          remaining = remaining_val.float.int64
        else:
          if remaining_val.to_bool:
            remaining = 1
          else:
            remaining = 0
        remaining.dec()
        when not defined(release):
          if self.trace:
            echo "IkRepeatDecCheck remaining=", remaining
        if remaining > 0:
          self.frame.push(remaining.to_value())
          self.pc = inst.arg0.int64.int
          if self.pc < self.cu.instructions.len:
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            break
        {.pop.}





      of IkTailCall:
        {.push checks: off}
        # IkTailCall works like IkGeneEnd but optimizes tail calls to the same function
        let value = self.frame.current()
        case value.kind:
          of VkFrame:
            let new_frame = value.ref.frame
            case new_frame.kind:
              of FkFunction, FkMethod, FkMacroMethod:
                let f = new_frame.target.ref.fn
                if f.body_compiled == nil:
                  f.compile()
                
                # Check if this is a tail call to the same function
                if is_function_like(self.frame.kind) and 
                   self.frame.target.kind == VkFunction and
                   self.frame.target.ref.fn == f:
                  # Tail call optimization - reuse current frame
                  # Pop the VkFrame value from the stack
                  discard self.frame.pop()
                  
                  # Update arguments and scope in place
                  self.frame.args = new_frame.args
                  
                  # Reset scope
                  if f.matcher.is_empty():
                    self.frame.scope = f.parent_scope
                    # Increment ref_count since the frame will own this reference
                    if self.frame.scope != nil:
                      self.frame.scope.ref_count.inc()
                  else:
                    self.frame.scope = new_scope(f.scope_tracker, f.parent_scope)
                    # Process arguments
                    if is_method_frame(self.frame):
                      # Method call - create args without self
                      var method_args = new_gene(NIL)
                      if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 1:
                        for i in 1..<self.frame.args.gene.children.len:
                          method_args.children.add(self.frame.args.gene.children[i])
                      process_args(f.matcher, method_args.to_gene_value(), self.frame.scope)
                    else:
                      process_args(f.matcher, self.frame.args, self.frame.scope)
                  
                  # Reset stack
                  self.frame.stack_index = 0
                  
                  # Jump to start of function body
                  self.pc = 0
                  inst = self.cu.instructions[self.pc].addr
                  continue
                else:
                  # Not a tail call - fall back to regular call like IkGeneEnd
                  self.pc.inc()
                  discard self.frame.pop()
                  new_frame.caller_frame = self.frame
                  self.frame.ref_count.inc()
                  new_frame.caller_address = Address(cu: self.cu, pc: self.pc)
                  new_frame.ns = f.ns
                  self.frame = new_frame
                  self.cu = f.body_compiled
                  
                  # Process arguments
                  if not f.matcher.is_empty():
                    if is_method_frame(new_frame):
                      var method_args = new_gene(NIL)
                      if new_frame.args.kind == VkGene and new_frame.args.gene.children.len > 1:
                        for i in 1..<new_frame.args.gene.children.len:
                          method_args.children.add(new_frame.args.gene.children[i])
                      process_args(f.matcher, method_args.to_gene_value(), new_frame.scope)
                    else:
                      process_args(f.matcher, new_frame.args, new_frame.scope)
                  
                  self.pc = 0
                  inst = self.cu.instructions[self.pc].addr
                  continue
              else:
                # For other frame kinds, just do regular call
                not_allowed("IkTailCall not supported for frame kind: " & $new_frame.kind)
          else:
            # For non-frames, fall back to IkGeneEnd behavior
            not_allowed("IkTailCall not supported for value kind: " & $value.kind)
        {.pop}

      of IkResolveSymbol:
        let symbol_key = cast[uint64](inst.arg0)
        case symbol_key:
          of SYM_UNDERSCORE:
            self.frame.push(PLACEHOLDER)
          of SYM_SELF:
            # Get self from first argument
            if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 0:
              self.frame.push(self.frame.args.gene.children[0])
            else:
              self.frame.push(NIL)
          of SYM_GENE:
            self.frame.push(App.app.gene_ns)
          of SYM_NS:
            # Return current namespace
            let r = new_ref(VkNamespace)
            r.ns = self.frame.ns
            self.frame.push(r.to_ref_value())
          else:
            let name = cast[Key](inst.arg0)
            
            # Inline cache implementation
            if self.pc < self.cu.inline_caches.len:
              # Check if cache hit
              let cache = self.cu.inline_caches[self.pc].addr
              if cache.ns != nil and cache.version == cache.ns.version and name in cache.ns.members:
                # Cache hit - use cached value
                self.frame.push(cache.ns.members[name])
              else:
                # Cache miss - do full lookup
                var value = if self.frame.ns != nil: self.frame.ns[name] else: NIL
                var found_ns = self.frame.ns
                if value == NIL:
                  # Try thread-local namespace first (for $thread, $main_thread, etc.)
                  if self.thread_local_ns != nil:
                    value = self.thread_local_ns[name]
                    if value != NIL:
                      found_ns = self.thread_local_ns
                
                # Update cache if we found the value
                if value != NIL:
                  cache.ns = found_ns
                  cache.version = found_ns.version
                  cache.value = value
                
                self.frame.push(value)
            else:
              # Extend cache array if needed
              while self.cu.inline_caches.len <= self.pc:
                self.cu.inline_caches.add(InlineCache())
              
              # Do full lookup
              var value = if self.frame.ns != nil: self.frame.ns[name] else: NIL
              var found_ns = self.frame.ns
              if value == NIL:
                # Try thread-local namespace first (for $thread, $main_thread, etc.)
                if self.thread_local_ns != nil:
                  value = self.thread_local_ns[name]
                  if value != NIL:
                    found_ns = self.thread_local_ns

              # Initialize cache if we found the value
              if value != NIL:
                self.cu.inline_caches[self.pc].ns = found_ns
                self.cu.inline_caches[self.pc].version = found_ns.version
                self.cu.inline_caches[self.pc].value = value
              
              self.frame.push(value)

      of IkSelf:
        # Get self from first argument
        if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 0:
          self.frame.push(self.frame.args.gene.children[0])
        else:
          self.frame.push(NIL)
      
      of IkSetSelf:
        # Set the value as self by modifying frame.args
        let value = self.frame.pop()
        # Ensure frame.args is a Gene with at least one child
        if self.frame.args.kind != VkGene:
          let args_gene = new_gene(NIL)
          args_gene.children.add(value)
          self.frame.args = args_gene.to_gene_value()
        elif self.frame.args.gene.children.len == 0:
          self.frame.args.gene.children.add(value)
        else:
          self.frame.args.gene.children[0] = value
      
      of IkRotate:
        # Rotate top 3 stack elements: [a, b, c] -> [c, a, b]
        let c = self.frame.pop()
        let b = self.frame.pop()
        let a = self.frame.pop()
        self.frame.push(c)
        self.frame.push(a)
        self.frame.push(b)
      
      of IkParse:
        let str_value = self.frame.pop()
        if str_value.kind != VkString:
          raise new_exception(types.Exception, "$parse expects a string")
        let parsed = read(str_value.str)
        self.frame.push(parsed)
      
      of IkRender:
        let template_value = self.frame.pop()
        let rendered = self.render_template(template_value)
        self.frame.push(rendered)
      
      of IkEval:
        let value = self.frame.pop()
        case value.kind:
          of VkSymbol:
            # For eval, we need to check local scope first, then namespaces
            let symbol_str = value.str
            if symbol_str.starts_with("$") and symbol_str.len > 1:
              if symbol_str == "$ns":
                let r = new_ref(VkNamespace)
                r.ns = self.frame.ns
                self.frame.push(r.to_ref_value())
              elif symbol_str == "$ex":
                let ex_value = if self.current_exception != NIL: self.current_exception else: self.repl_exception
                self.frame.push(ex_value)
              else:
                let key = symbol_str[1..^1].to_key()
                let resolved = App.app.global_ns.ref.ns[key]
                if resolved == NIL:
                  not_allowed("Unknown symbol: " & symbol_str)
                self.frame.push(resolved)
            else:
              let key = symbol_str.to_key()
              
              # First check if it's a local variable in the current scope
              var found_in_scope = false
              if self.frame.scope != nil and self.frame.scope.tracker != nil:
                let found = self.frame.scope.tracker.locate(key)
                if found.local_index >= 0:
                  # Variable found in scope
                  var scope = self.frame.scope
                  var parent_index = found.parent_index
                  while parent_index > 0:
                    parent_index.dec()
                    scope = scope.parent
                  self.frame.push(scope.members[found.local_index])
                  found_in_scope = true
              
              if not found_in_scope:
                # Not a local variable, look in namespaces
                var r = if self.frame.ns != nil: self.frame.ns[key] else: NIL
                if r == NIL:
                  if self.thread_local_ns != nil:
                    r = self.thread_local_ns[key]
                if r == NIL:
                  not_allowed("Unknown symbol: " & symbol_str)
                self.frame.push(r)
          of VkGene:
            # Evaluate a gene expression - compile and execute it
            let compiled = compile_init(value)
            # Save current state
            let saved_cu = self.cu
            let saved_pc = self.pc
            # Execute the compiled code
            self.cu = compiled
            let eval_result = self.exec()
            # Restore state
            self.cu = saved_cu
            self.pc = saved_pc
            inst = self.cu.instructions[self.pc].addr
            self.frame.push(eval_result)
          of VkQuote:
            # Evaluate a quoted expression by compiling and executing the quoted value
            let quoted_value = value.ref.quote
            let compiled = compile_init(quoted_value)
            # Save current state
            let saved_cu = self.cu
            let saved_pc = self.pc
            # Execute the compiled code
            self.cu = compiled
            let eval_result = self.exec()
            # Restore state
            self.cu = saved_cu
            self.pc = saved_pc
            inst = self.cu.instructions[self.pc].addr
            self.frame.push(eval_result)
          else:
            # For other types, just push them back (already evaluated)
            self.frame.push(value)

      of IkSetMember:
        let name = cast[Key](inst.arg0.raw)
        var value: Value
        self.frame.pop2(value)
        var target: Value
        self.frame.pop2(target)
        case target.kind:
          of VkNil:
            # Trying to set member on nil - likely namespace doesn't exist
            let symbol_index = cast[uint64](name) and PAYLOAD_MASK
            let symbol_name = get_symbol(symbol_index.int)
            not_allowed("Cannot set member '" & symbol_name & "' on nil (namespace or object doesn't exist)")
          of VkMap:
            map_data(target)[name] = value
          of VkGene:
            target.gene.props[name] = value
          of VkNamespace:
            target.ref.ns[name] = value
          of VkClass:
            target.ref.class.ns[name] = value
          of VkInstance:
            instance_props(target)[name] = value
          of VkArray:
            # Arrays don't support named members, this is likely an error
            let symbol_index = cast[uint64](name) and PAYLOAD_MASK
            let symbol_name = get_symbol(symbol_index.int)
            not_allowed("Cannot set named member '" & symbol_name & "' on array")
          else:
            not_allowed("Cannot set member on value of type: " & $target.kind)
        self.frame.push(value)

      of IkSetMemberDynamic:
        var value: Value
        self.frame.pop2(value)
        var prop: Value
        self.frame.pop2(prop)
        var target: Value
        self.frame.pop2(target)

        if target == NIL:
          not_allowed("Cannot set member on nil (namespace or object doesn't exist)")

        case target.kind:
        of VkMap, VkNamespace, VkClass, VkInstance:
          let key = case prop.kind:
            of VkString, VkSymbol: prop.str.to_key()
            of VkInt: ($prop.int64).to_key()
            else:
              not_allowed("Invalid property type: " & $prop.kind)
              "".to_key()
          case target.kind:
            of VkMap:
              map_data(target)[key] = value
            of VkNamespace:
              target.ref.ns[key] = value
            of VkClass:
              target.ref.class.ns[key] = value
            of VkInstance:
              instance_props(target)[key] = value
            else:
              discard
        of VkGene:
          case prop.kind:
            of VkInt:
              let idx = prop.int64
              let children_len = target.gene.children.len.int64
              if idx < 0 or idx >= children_len:
                not_allowed("Gene child index out of bounds: " & $idx & " (len=" & $children_len & ")")
              target.gene.children[idx.int] = value
            of VkString, VkSymbol:
              target.gene.props[prop.str.to_key()] = value
            else:
              not_allowed("Invalid property type: " & $prop.kind)
        of VkArray:
          if prop.kind != VkInt:
            not_allowed("Array index must be an integer")
          let idx = prop.int64
          let arr_len = array_data(target).len.int64
          if idx < 0 or idx >= arr_len:
            not_allowed("Array index out of bounds: " & $idx & " (len=" & $arr_len & ")")
          array_data(target)[idx.int] = value
        else:
          not_allowed("Cannot set member on value of type: " & $target.kind)

        self.frame.push(value)

      of IkGetMember:
        # arg0 contains a symbol Value - use it directly as Key
        let symbol_value = inst.arg0
        let name = cast[Key](symbol_value)
        var value: Value
        self.frame.pop2(value)

        # Check for NIL first to give better error message
        if value.kind == VkNil:
          let symbol_index = cast[uint64](name) and PAYLOAD_MASK
          let symbol_name = get_symbol(symbol_index.int)
          not_allowed("Cannot access member '" & symbol_name & "' on nil value")
        
        case value.kind:
          of VkNil:
            # Already handled above, but needed for exhaustive case
            discard
          of VkMap:
            let member = map_data(value)[name]
            retain(member)
            self.frame.push(member)
          of VkGene:
            let member = value.gene.props[name]
            retain(member)
            self.frame.push(member)
          of VkNamespace:
            # Special handling for $ex (gene/ex or global/ex)
            if name == "ex".to_key() and (value == App.app.gene_ns or value == App.app.global_ns):
              # Return current exception if set, otherwise the REPL exception
              let ex_value = if self.current_exception != NIL: self.current_exception else: self.repl_exception
              self.frame.push(ex_value)
            elif value.ref.ns == App.app.genex_ns.ref.ns:
              # Auto-load extensions when accessing genex/name
              var member = value.ref.ns[name]
              if member == NIL:
                # Try to load the extension
                let symbol_index = cast[uint64](name) and PAYLOAD_MASK
                let ext_name = get_symbol(symbol_index.int)
                let ext_path = "build/lib" & ext_name & ".dylib"
                when not defined(noExtensions):
                  try:
                    let ext_ns = load_extension(self, ext_path)
                    value.ref.ns[name] = ext_ns.to_value()
                    member = ext_ns.to_value()
                  except CatchableError:
                    discard
              retain(member)
              self.frame.push(member)
            else:
              let member = value.ref.ns[name]
              retain(member)
              self.frame.push(member)
          of VkClass:
            # Check members first (static methods), then ns (namespace members)
            let member = value.ref.class.get_member(name)
            let resolved = if member != NIL: member else: value.ref.class.ns[name]
            retain(resolved)
            self.frame.push(resolved)
          of VkEnum:
            # Access enum member
            let member_name = $name
            if member_name in value.ref.enum_def.members:
              let member = value.ref.enum_def.members[member_name].to_value()
              retain(member)
              self.frame.push(member)
            else:
              not_allowed("enum " & value.ref.enum_def.name & " has no member " & member_name)
          of VkInstance:
            if name in instance_props(value):
              let member = instance_props(value)[name]
              retain(member)
              self.frame.push(member)
            else:
              self.frame.push(NIL)
          of VkRegexMatch:
            let key = cast[Value](name).str
            var member = NIL
            case key
            of "value":
              member = value.ref.regex_match_value.to_value()
            of "captures":
              var caps = new_array_value()
              for item in value.ref.regex_match_captures:
                array_data(caps).add(item.to_value())
              member = caps
            of "start":
              member = value.ref.regex_match_start.to_value()
            of "end":
              member = value.ref.regex_match_end.to_value()
            else:
              member = NIL
            retain(member)
            self.frame.push(member)
          else:
            when not defined(release):
              echo "IkGetMember: Attempting to access member '", name, "' on value of type ", value.kind
            not_allowed("Cannot get member '" & $name & "' on value of type: " & $value.kind)

      of IkGetMemberOrNil:
        # Pop property/index, then target
        var prop: Value
        self.frame.pop2(prop)
        var target: Value
        self.frame.pop2(target)

        # Not found returns VOID by default. Use /! (IkAssertNotVoid) to throw.
        if target == VOID or target == NIL:
          self.frame.push(VOID)
        else:
          case target.kind:
            of VkMap:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              let member = map_data(target).getOrDefault(key, VOID)
              retain(member)
              self.frame.push(member)
            of VkGene:
              if prop.kind == VkInt:
                let idx64 = prop.int64
                let children_len = target.gene.children.len.int64
                var resolved = idx64
                if resolved < 0:
                  resolved = children_len + resolved
                if resolved >= 0 and resolved < children_len:
                  let member = target.gene.children[resolved.int]
                  retain(member)
                  self.frame.push(member)
                else:
                  self.frame.push(VOID)
              else:
                let key = case prop.kind:
                  of VkString, VkSymbol: prop.str.to_key()
                  of VkInt: ($prop.int64).to_key()
                  else:
                    not_allowed("Invalid property type: " & $prop.kind)
                    "".to_key()
                if key in target.gene.props:
                  let member = target.gene.props[key]
                  retain(member)
                  self.frame.push(member)
                else:
                  self.frame.push(VOID)
            of VkNamespace:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              # Special handling for $ex (gene/ex)
              if key == "ex".to_key() and (target == App.app.gene_ns or target == App.app.global_ns):
                let member = if self.current_exception != NIL: self.current_exception else: self.repl_exception
                retain(member)
                self.frame.push(member)
              elif key == "duration_start".to_key() and (target == App.app.gene_ns or target == App.app.global_ns):
                let now_us = epochTime() * 1_000_000
                self.duration_start_us = now_us
                self.frame.push(now_us.to_value())
              elif key == "duration".to_key() and (target == App.app.gene_ns or target == App.app.global_ns):
                if self.duration_start_us == 0.0:
                  not_allowed("duration_start is not set")
                let now_us = epochTime() * 1_000_000
                let elapsed = now_us - self.duration_start_us
                self.frame.push(elapsed.to_value())
              elif target.ref.ns.has_key(key):
                let member = target.ref.ns[key]
                retain(member)
                self.frame.push(member)
              else:
                self.frame.push(VOID)
            of VkClass:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              if target.ref.class.ns.has_key(key):
                let member = target.ref.class.ns[key]
                retain(member)
                self.frame.push(member)
              else:
                self.frame.push(VOID)
            of VkEnum:
              let member_name = case prop.kind:
                of VkString, VkSymbol: prop.str
                of VkInt: $prop.int64
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  ""
              if member_name in target.ref.enum_def.members:
                let member = target.ref.enum_def.members[member_name].to_value()
                retain(member)
                self.frame.push(member)
              else:
                self.frame.push(VOID)
            of VkInstance:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              let member = instance_props(target).getOrDefault(key, VOID)
              retain(member)
              self.frame.push(member)
            of VkRegexMatch:
              if prop.kind != VkString and prop.kind != VkSymbol:
                not_allowed("RegexMatch member access expects string or symbol")
              let key = prop.str
              var member = VOID
              case key
              of "value":
                member = target.ref.regex_match_value.to_value()
              of "captures":
                var caps = new_array_value()
                for item in target.ref.regex_match_captures:
                  array_data(caps).add(item.to_value())
                member = caps
              of "start":
                member = target.ref.regex_match_start.to_value()
              of "end":
                member = target.ref.regex_match_end.to_value()
              else:
                member = VOID
              retain(member)
              self.frame.push(member)
            of VkArray:
              if prop.kind == VkInt:
                let idx64 = prop.int64
                let arr = array_data(target)
                let arr_len = arr.len.int64
                var resolved = idx64
                if resolved < 0:
                  resolved = arr_len + resolved
                if resolved >= 0 and resolved < arr_len:
                  let member = arr[resolved.int]
                  retain(member)
                  self.frame.push(member)
                else:
                  self.frame.push(VOID)
              else:
                self.frame.push(VOID)
            else:
              self.frame.push(VOID)
      
      of IkGetMemberDefault:
        # Pop default value, property/index, then target
        var default_val: Value
        self.frame.pop2(default_val)
        var prop: Value
        self.frame.pop2(prop)
        var target: Value
        self.frame.pop2(target)

        if target == VOID or target == NIL:
          retain(default_val)
          self.frame.push(default_val)
        else:
          case target.kind:
            of VkMap:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              let member = map_data(target).getOrDefault(key, default_val)
              retain(member)
              self.frame.push(member)
            of VkGene:
              if prop.kind == VkInt:
                let idx64 = prop.int64
                let children_len = target.gene.children.len.int64
                var resolved = idx64
                if resolved < 0:
                  resolved = children_len + resolved
                if resolved >= 0 and resolved < children_len:
                  let member = target.gene.children[resolved.int]
                  retain(member)
                  self.frame.push(member)
                else:
                  retain(default_val)
                  self.frame.push(default_val)
              else:
                let key = case prop.kind:
                  of VkString, VkSymbol: prop.str.to_key()
                  of VkInt: ($prop.int64).to_key()
                  else:
                    not_allowed("Invalid property type: " & $prop.kind)
                    "".to_key()
                if key in target.gene.props:
                  let member = target.gene.props[key]
                  retain(member)
                  self.frame.push(member)
                else:
                  retain(default_val)
                  self.frame.push(default_val)
            of VkNamespace:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              # Special handling for $ex (gene/ex)
              if key == "ex".to_key() and target == App.app.gene_ns:
                let member = self.current_exception
                retain(member)
                self.frame.push(member)
              elif target.ref.ns.has_key(key):
                let member = target.ref.ns[key]
                retain(member)
                self.frame.push(member)
              else:
                retain(default_val)
                self.frame.push(default_val)
            of VkClass:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              if target.ref.class.ns.has_key(key):
                let member = target.ref.class.ns[key]
                retain(member)
                self.frame.push(member)
              else:
                retain(default_val)
                self.frame.push(default_val)
            of VkEnum:
              let member_name = case prop.kind:
                of VkString, VkSymbol: prop.str
                of VkInt: $prop.int64
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  ""
              if member_name in target.ref.enum_def.members:
                let member = target.ref.enum_def.members[member_name].to_value()
                retain(member)
                self.frame.push(member)
              else:
                retain(default_val)
                self.frame.push(default_val)
            of VkInstance:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              let member = instance_props(target).getOrDefault(key, default_val)
              retain(member)
              self.frame.push(member)
            of VkArray:
              if prop.kind == VkInt:
                let idx64 = prop.int64
                let arr = array_data(target)
                let arr_len = arr.len.int64
                var resolved = idx64
                if resolved < 0:
                  resolved = arr_len + resolved
                if resolved >= 0 and resolved < arr_len:
                  let member = arr[resolved.int]
                  retain(member)
                  self.frame.push(member)
                else:
                  retain(default_val)
                  self.frame.push(default_val)
              else:
                retain(default_val)
                self.frame.push(default_val)
            else:
              retain(default_val)
              self.frame.push(default_val)

      of IkAssertNotVoid:
        let value = self.frame.current()
        if value == VOID:
          not_allowed("Selector did not match (VOID)")

      of IkCreateSelector:
        let count = inst.arg1
        if count <= 0:
          not_allowed("Selector requires at least one segment")
        var segments = newSeq[Value](count)
        for i in countdown(count - 1, 0):
          var seg: Value
          self.frame.pop2(seg)
          segments[i] = seg
        self.frame.push(new_selector_value(segments))

      of IkSetChild:
        let i = inst.arg0.int64
        var new_value: Value
        self.frame.pop2(new_value)
        var target: Value
        self.frame.pop2(target)
        case target.kind:
          of VkArray:
            let arr_len = array_data(target).len.int64
            if i < 0 or i >= arr_len:
              not_allowed("Array index out of bounds: " & $i & " (len=" & $arr_len & ")")
            array_data(target)[i] = new_value
          of VkGene:
            let children_len = target.gene.children.len.int64
            if i < 0 or i >= children_len:
              not_allowed("Gene child index out of bounds: " & $i & " (len=" & $children_len & ")")
            target.gene.children[i] = new_value
          else:
            when not defined(release):
              if self.trace:
                echo fmt"IkSetChild unsupported kind: {target.kind}"
            not_allowed("Cannot set child on value of type: " & $target.kind)
        self.frame.push(new_value)

      of IkGetChild:
        let i = inst.arg0.int64
        var value: Value
        self.frame.pop2(value)
        case value.kind:
          of VkArray:
            let arr_len = array_data(value).len.int64
            if i < 0 or i >= arr_len:
              not_allowed("Array index out of bounds: " & $i & " (len=" & $arr_len & ")")
            let child = array_data(value)[i]
            retain(child)
            self.frame.push(child)
          of VkGene:
            let children_len = value.gene.children.len.int64
            if i < 0 or i >= children_len:
              not_allowed("Gene child index out of bounds: " & $i & " (len=" & $children_len & ")")
            let child = value.gene.children[i]
            retain(child)
            self.frame.push(child)
          else:
            when not defined(release):
              if self.trace:
                echo fmt"IkGetChild unsupported kind: {value.kind}"
            not_allowed("Cannot get child from value of type: " & $value.kind)
      of IkGetChildDynamic:
        # Get child using index from stack
        # Stack order: [... collection index]
        var index: Value
        self.frame.pop2(index)
        var collection: Value  
        self.frame.pop2(collection)
        let i = index.int64.int
        when not defined(release):
          if self.trace:
            echo fmt"IkGetChildDynamic: collection={collection}, index={index}"
        case collection.kind:
          of VkArray:
            let arr_len = array_data(collection).len
            if i < 0 or i >= arr_len:
              not_allowed("Array index out of bounds: " & $i & " (len=" & $arr_len & ")")
            let child = array_data(collection)[i]
            retain(child)
            self.frame.push(child)
          of VkGene:
            let children_len = collection.gene.children.len
            if i < 0 or i >= children_len:
              not_allowed("Gene child index out of bounds: " & $i & " (len=" & $children_len & ")")
            let child = collection.gene.children[i]
            retain(child)
            self.frame.push(child)
          of VkRange:
            # Calculate the i-th element in the range
            let start = collection.ref.range_start.int64
            let step = if collection.ref.range_step == NIL: 1 else: collection.ref.range_step.int64
            let value = start + (i * step)
            self.frame.push(value.to_value())
          else:
            when not defined(release):
              if self.trace:
                echo fmt"IkGetChildDynamic unsupported kind: {collection.kind}"
            not_allowed("Cannot get child from value of type: " & $collection.kind)

      of IkJump:
        {.push checks: off}
        let target = inst.arg0.int64.int
        if target < self.pc:
          self.poll_event_loop()
        self.pc = target
        inst = self.cu.instructions[self.pc].addr
        continue
        {.pop.}
      of IkJumpIfFalse:
        {.push checks: off}
        var value: Value
        self.frame.pop2(value)
        if not value.to_bool():
          let target = inst.arg0.int64.int
          if target < self.pc:
            self.poll_event_loop()
          self.pc = target
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkJumpIfMatchSuccess:
        {.push checks: off}
        # if self.frame.match_result.fields[inst.arg0.int64] == MfSuccess:
        let index = inst.arg0.int64.int
        if self.frame.scope.members.len > index:
          let target = inst.arg1.int32.int
          if target < self.pc:
            self.poll_event_loop()
          self.pc = target
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkLoopStart, IkLoopEnd:
        discard

      of IkContinue:
        {.push checks: off}
        let label = inst.arg0.int64.int
        
        # Check if this is a continue outside of a loop
        if label == -1:
          # Check if we're in a finally block
          var in_finally = false
          if self.exception_handlers.len > 0:
            let handler = self.exception_handlers[^1]
            if handler.in_finally:
              in_finally = true
          
          if in_finally:
            # Pop the value that continue would have used
            if self.frame.stack_index > 0:
              discard self.frame.pop()
            # Silently ignore continue in finally block
            discard
          else:
            not_allowed("continue used outside of a loop")
        else:
          # Normal continue - jump to the start label
          if label < self.pc:
            self.poll_event_loop()
          self.pc = label
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkBreak:
        {.push checks: off}
        let label = inst.arg0.int64.int
        
        # Check if this is a break outside of a loop
        if label == -1:
          # Check if we're in a finally block
          var in_finally = false
          if self.exception_handlers.len > 0:
            let handler = self.exception_handlers[^1]
            if handler.in_finally:
              in_finally = true
          
          if in_finally:
            # Pop the value that break would have used
            if self.frame.stack_index > 0:
              discard self.frame.pop()
            # Silently ignore break in finally block
            discard
          else:
            not_allowed("break used outside of a loop")
        else:
          # Normal break - jump to the end label
          if label < self.pc:
            self.poll_event_loop()
          self.pc = label
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkPushValue:
        if inst.arg0.kind == VkString:
          # String literals are mutable; avoid mutating shared constants.
          self.frame.push(new_str_value(inst.arg0.str))
        else:
          self.frame.push(inst.arg0)
      of IkPushNil:
        self.frame.push(NIL)
      of IkPop:
        discard self.frame.pop()
      of IkDup:
        let value = self.frame.current()
        when not defined(release):
          if self.trace:
            echo fmt"IkDup: duplicating {value}"
        self.frame.push(value)
      of IkDup2:
        # Duplicate top two stack elements
        let top = self.frame.pop()
        let second = self.frame.pop()
        self.frame.push(second)
        self.frame.push(top)
        self.frame.push(second)
        self.frame.push(top)
      of IkDupSecond:
        # Duplicate second element from stack
        # Stack: [... second top] -> [... second top second]
        let top = self.frame.pop()
        let second = self.frame.pop()
        when not defined(release):
          if self.trace:
            echo fmt"IkDupSecond: top={top}, second={second}"
        self.frame.push(second)  # Put second back
        self.frame.push(top)     # Put top back
        self.frame.push(second)  # Push duplicate of second
      of IkSwap:
        # Swap top two stack elements
        let top = self.frame.pop()
        let second = self.frame.pop()
        self.frame.push(top)
        self.frame.push(second)
      of IkOver:
        # Copy second element to top: [a b] -> [a b a]
        let top = self.frame.pop()
        let second = self.frame.current()
        when not defined(release):
          if self.trace:
            echo fmt"IkOver: top={top}, second={second}"
        self.frame.push(top)
        self.frame.push(second)
      of IkLen:
        # Get length of collection
        let value = self.frame.pop()
        let length = value.size()
        when not defined(release):
          if self.trace:
            echo fmt"IkLen: size({value}) = {length}"
        self.frame.push(length.to_value())

      of IkArrayStart:
        # Mark current stack position as array base
        self.frame.collection_bases.push(self.frame.stack_index)

      of IkArrayAddSpread:
        # Spread operator - pop array and push all its elements onto stack
        let value = self.frame.pop()
        case value.kind:
          of VkArray:
            # Push each element onto stack
            for item in array_data(value):
              self.frame.push(item)
          of VkNil:
            # Spreading nil is a no-op (treat as empty array)
            discard
          else:
            not_allowed("... can only spread arrays in array context, got " & $value.kind)

      of IkArrayEnd:
        # Collect all elements from call base into array
        let base = self.frame.collection_bases.pop()
        let count = int(self.frame.stack_index) - int(base)

        # Create array with exact capacity
        let arr = new_array_value()
        if count > 0:
          array_data(arr).setLen(count)
          # Copy elements from stack
          for i in 0..<count:
            array_data(arr)[i] = self.frame.stack[base + uint16(i)]

        # Pop all elements and push array
        self.frame.stack_index = base
        self.frame.push(arr)

      of IkStreamStart:
        self.frame.collection_bases.push(self.frame.stack_index)

      of IkStreamAddSpread:
        let value = self.frame.pop()
        var seq_to_spread: seq[Value]
        case value.kind
        of VkArray:
          seq_to_spread = array_data(value)
        of VkStream:
          seq_to_spread = value.ref.stream
        of VkNil:
          # Spreading nil is a no-op (treat as empty stream)
          seq_to_spread = @[]
        else:
          not_allowed("... can only spread arrays or streams in stream context, got " & $value.kind)

        for item in seq_to_spread:
          self.frame.push(item)

      of IkStreamEnd:
        let base = self.frame.collection_bases.pop()
        let count = int(self.frame.stack_index) - int(base)

        let stream_ref = new_ref(VkStream)
        stream_ref.stream.setLen(count)
        for i in 0..<count:
          stream_ref.stream[i] = self.frame.stack[base + uint16(i)]
        stream_ref.stream_index = 0
        stream_ref.stream_ended = false

        self.frame.stack_index = base
        self.frame.push(stream_ref.to_ref_value())

      of IkMapStart:
        self.frame.push(new_map_value())
      of IkMapSetProp:
        let key = cast[Key](inst.arg0.raw)
        var value: Value
        self.frame.pop2(value)
        map_data(self.frame.current())[key] = value
      of IkMapSetPropValue:
        # Set property with literal value
        let key = cast[Key](inst.arg0.raw)
        map_data(self.frame.current())[key] = inst.arg1
      of IkMapSpread:
        # Spread map key-value pairs into current map
        let value = self.frame.pop()
        case value.kind:
          of VkMap:
            for k, v in map_data(value):
              map_data(self.frame.current())[k] = v
          of VkNil:
            # Spreading nil is a no-op (treat as empty map)
            discard
          else:
            not_allowed("... can only spread maps in map context, got " & $value.kind)
      of IkMapEnd:
        discard

      of IkGeneStart:
        self.frame.push(new_gene_value())

      of IkGeneStartDefault:
        {.push checks: off}
        let gene_type = self.frame.current()
        case gene_type.kind:
          of VkFunction:
            let f = gene_type.ref.fn

            # Check if this is a generator function
            if f.is_generator:
              # Don't create generator here, just continue to collect arguments
              # The generator will be created in IkGeneEnd
              self.frame.push(new_gene_value())
              self.frame.current().gene.type = gene_type
              self.pc.inc()
              inst = self.cu.instructions[self.pc].addr
              continue

            # Check if this is a macro-like function
            if f.is_macro_like:
              # Macro-like function: use quoted arguments branch
              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                # Increment ref_count since the frame will own this reference
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var r = new_ref(VkFrame)
              r.frame = new_frame()
              r.frame.kind = FkMacro
              r.frame.target = gene_type
              r.frame.scope = scope

              # Pass caller's context as implicit argument (for $caller_eval)
              r.frame.caller_context = self.frame

              self.frame.replace(r.to_ref_value())
              # Continue to next instruction (macro branch with quoted args)
              self.pc.inc()
              inst = self.cu.instructions[self.pc].addr
              continue
            else:
              # Normal function call: use evaluated arguments branch
              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                # Increment ref_count since the frame will own this reference
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var r = new_ref(VkFrame)
              r.frame = new_frame()
              r.frame.kind = FkFunction
              r.frame.target = gene_type
              r.frame.scope = scope
              self.frame.replace(r.to_ref_value())
              # Jump to function branch (evaluated arguments)
              # inst.arg0 contains fn_label which is the start of function branch
              self.pc = inst.arg0.int64.int
              inst = self.cu.instructions[self.pc].addr
              continue

          of VkBlock:
            # if inst.arg1 == 2:
            #   not_allowed("Macro not allowed here")
            # inst.arg1 = 1

            var scope: Scope
            let b = gene_type.ref.block
            if b.matcher.is_empty():
              scope = b.frame.scope
            else:
              scope = new_scope(b.scope_tracker, b.frame.scope)

            var r = new_ref(VkFrame)
            r.frame = new_frame()
            r.frame.kind = FkBlock
            r.frame.target = gene_type
            r.frame.scope = scope
            self.frame.replace(r.to_ref_value())
            self.pc = inst.arg0.int64.int
            inst = self.cu.instructions[self.pc].addr
            continue

          of VkNativeFn:
            var r = new_ref(VkNativeFrame)
            r.native_frame = NativeFrame(
              kind: NfFunction,
              target: gene_type,
              args: new_gene_value(),
            )
            self.frame.replace(r.to_ref_value())
            # Jump to collect arguments (same as regular functions)
            self.pc = inst.arg0.int64.int
            inst = self.cu.instructions[self.pc].addr
            continue

          of VkNativeMacro:
            # Native macro: collect unevaluated args like a generator
            # Store the native macro as the Gene's type so IkGeneEnd can call it
            self.frame.push(new_gene_value())
            self.frame.current().gene.type = gene_type
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

          of VkBoundMethod:
            # Handle bound method calls
            let bm = gene_type.ref.bound_method
            let meth = bm.`method`
            let target = meth.callable
            
            case target.kind:
              of VkFunction:
                # Create a new frame for the method call
                var scope: Scope
                let f = target.ref.fn
                if f.matcher.is_empty():
                  scope = f.parent_scope
                  # Increment ref_count since the frame will own this reference
                  if scope != nil:
                    scope.ref_count.inc()
                else:
                  scope = new_scope(f.scope_tracker, f.parent_scope)
                
                var r = new_ref(VkFrame)
                r.frame = new_frame()
                r.frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
                r.frame.target = target
                r.frame.scope = scope
                if f.is_macro_like:
                  r.frame.caller_context = self.frame
                # Prepare args with self as first argument
                let args_gene = new_gene(NIL)
                args_gene.children.add(bm.self)
                # Copy any existing args from the current frame (for method calls with arguments)
                if self.frame.current().kind == VkFrame and self.frame.current().ref.frame.args.kind == VkGene:
                  for child in self.frame.current().ref.frame.args.gene.children:
                    args_gene.children.add(child)
                r.frame.args = args_gene.to_gene_value()
                self.frame.replace(r.to_ref_value())
                self.pc = inst.arg0.int64.int
                inst = self.cu.instructions[self.pc].addr
                continue
              of VkNativeFn:
                # Handle native function methods
                # Create a native frame for the method call
                var nf = new_ref(VkNativeFrame)
                nf.native_frame = NativeFrame(
                  kind: NfMethod,
                  target: target,
                  args: new_gene(NIL).to_gene_value()
                )
                # Add self as first argument
                nf.native_frame.args.gene.children.add(bm.self)
                self.frame.replace(nf.to_ref_value())
                self.pc = inst.arg0.int64.int
                inst = self.cu.instructions[self.pc].addr
                continue
              else:
                not_allowed("Method must be a function, got " & $target.kind)
          
          of VkInstance, VkCustom:
            # Check if instance has a call method
            let call_method_key = "call".to_key()
            let instance_class = gene_type.get_object_class()
            if instance_class != nil and instance_class.methods.hasKey(call_method_key):
              # Instance has a call method, create a frame for it
              let meth = instance_class.methods[call_method_key]
              let target = meth.callable
              
              case target.kind:
                of VkFunction:
                  # Create a new frame for the call method
                  var scope: Scope
                  let f = target.ref.fn
                  if f.matcher.is_empty():
                    scope = f.parent_scope
                    # Increment ref_count since the frame will own this reference
                    if scope != nil:
                      scope.ref_count.inc()
                  else:
                    scope = new_scope(f.scope_tracker, f.parent_scope)
                  
                  var r = new_ref(VkFrame)
                  r.frame = new_frame()
                  r.frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
                  r.frame.target = target
                  r.frame.scope = scope
                  if f.is_macro_like:
                    r.frame.caller_context = self.frame
                  # Initialize args with instance as first argument (self)
                  # Additional arguments will be collected by IkGeneAddChild
                  let args_gene = new_gene(NIL)
                  args_gene.children.add(gene_type)  # Add instance as self
                  r.frame.args = args_gene.to_gene_value()
                  self.frame.replace(r.to_ref_value())
                  # Continue to collect arguments, don't jump yet
                  self.pc = inst.arg0.int64.int
                  inst = self.cu.instructions[self.pc].addr
                  continue
                of VkNativeFn:
                  # Handle native function call methods
                  var nf = new_ref(VkNativeFrame)
                  nf.native_frame = NativeFrame(
                    kind: NfMethod,
                    target: target,
                    args: new_gene(NIL).to_gene_value()
                  )
                  # Add instance as first argument (self)
                  # Additional arguments will be collected by IkGeneAddChild
                  nf.native_frame.args.gene.children.add(gene_type)
                  self.frame.replace(nf.to_ref_value())
                  # Continue to collect arguments, don't jump yet
                  self.pc = inst.arg0.int64.int
                  inst = self.cu.instructions[self.pc].addr
                  continue
                else:
                  not_allowed("Call method must be a function, got " & $target.kind)
            else:
              # No call method, treat as regular gene
              var g = new_gene_value()
              g.gene.type = gene_type
              self.frame.push(g)

          else:
            # For non-callable types (like integers, strings, etc.), 
            # create a gene with this value as the type
            var g = new_gene_value()
            g.gene.type = gene_type
            self.frame.push(g)


      of IkGeneSetType:
        {.push checks: off}
        var value: Value
        self.frame.pop2(value)
        self.frame.current().gene.type = value
        {.pop.}
      of IkGeneSetProp:
        {.push checks: off}
        let key = cast[Key](inst.arg0.raw)
        var value: Value
        self.frame.pop2(value)
        let current = self.frame.current()
        case current.kind:
          of VkGene:
            current.gene.props[key] = value
          of VkFrame:
            # For function calls, we need to set up the args gene with properties
            if current.ref.frame.args.kind != VkGene:
              current.ref.frame.args = new_gene_value()
            current.ref.frame.args.gene.props[key] = value
          of VkNativeFrame:
            # For native function calls, ignore property setting for now
            discard
          else:
            not_allowed("Cannot set property on value of type: " & $current.kind)
        {.pop.}
      of IkGeneAddChild:
        {.push checks: off}
        var child: Value
        self.frame.pop2(child)
        let v = self.frame.current()
        when DEBUG_VM:
          echo "IkGeneAddChild: v.kind = ", v.kind, ", child = ", child
        when not defined(release):
          # Debug: print stack state when error occurs
          if v.kind == VkSymbol:
            echo "ERROR: IkGeneAddChild with Symbol on stack!"
            echo "  child = ", child
            echo "  v (stack top) = ", v
            echo "  Stack trace:"
            for i in 0..<min(5, self.frame.stack_index.int):
              echo "    [", i, "] = ", self.frame.stack[i]
        case v.kind:
          of VkFrame:
            # For function calls, we need to set up the args gene with children
            if v.ref.frame.args.kind != VkGene:
              v.ref.frame.args = new_gene_value()
            v.ref.frame.args.gene.children.add(child)
          of VkNativeFrame:
            v.ref.native_frame.args.gene.children.add(child)
          of VkGene:
            v.gene.children.add(child)
          of VkNil:
            # Skip adding to nil - this might happen happen in conditional contexts
            discard
          of VkBoundMethod:
            # For bound methods, we might need to handle arguments
            # For now, treat similar to nil and skip
            discard
          else:
            # For other value types, we can't add children directly
            # This might be an error in the compilation or a special case
            not_allowed("Cannot add child to value of type: " & $v.kind)
        {.pop.}

      of IkGeneAdd:
        # Same as IkGeneAddChild - add single child
        {.push checks: off}
        var child: Value
        self.frame.pop2(child)
        let v = self.frame.current()
        case v.kind:
          of VkFrame:
            if v.ref.frame.args.kind != VkGene:
              v.ref.frame.args = new_gene_value()
            v.ref.frame.args.gene.children.add(child)
          of VkNativeFrame:
            v.ref.native_frame.args.gene.children.add(child)
          of VkGene:
            v.gene.children.add(child)
          of VkNil:
            discard
          of VkBoundMethod:
            discard
          else:
            not_allowed("Cannot add to value of type: " & $v.kind)
        {.pop.}

      of IkGeneAddSpread:
        # Spread array into gene children
        {.push checks: off}
        let value = self.frame.pop()
        let v = self.frame.current()
        case value.kind:
          of VkArray:
            case v.kind:
              of VkFrame:
                if v.ref.frame.args.kind != VkGene:
                  v.ref.frame.args = new_gene_value()
                for item in array_data(value):
                  v.ref.frame.args.gene.children.add(item)
              of VkNativeFrame:
                for item in array_data(value):
                  v.ref.native_frame.args.gene.children.add(item)
              of VkGene:
                for item in array_data(value):
                  v.gene.children.add(item)
              else:
                not_allowed("... can only spread arrays into gene children, got " & $v.kind)
          of VkNil:
            # Spreading nil is a no-op (treat as empty array)
            discard
          else:
            not_allowed("... can only spread arrays in gene children context, got " & $value.kind)
        {.pop.}

      of IkGeneAddChildValue:
        # Add a literal value as gene child
        {.push checks: off}
        let v = self.frame.current()
        case v.kind:
          of VkFrame:
            if v.ref.frame.args.kind != VkGene:
              v.ref.frame.args = new_gene_value()
            v.ref.frame.args.gene.children.add(inst.arg0)
          of VkNativeFrame:
            v.ref.native_frame.args.gene.children.add(inst.arg0)
          of VkGene:
            v.gene.children.add(inst.arg0)
          else:
            not_allowed("Cannot add child value to type: " & $v.kind)
        {.pop.}

      of IkGeneSetPropValue:
        # Set property with literal value
        {.push checks: off}
        let key = cast[Key](inst.arg0.raw)
        let current = self.frame.current()
        case current.kind:
          of VkGene:
            current.gene.props[key] = inst.arg1
          of VkFrame:
            if current.ref.frame.args.kind != VkGene:
              current.ref.frame.args = new_gene_value()
            current.ref.frame.args.gene.props[key] = inst.arg1
          of VkNativeFrame:
            discard
          else:
            not_allowed("Cannot set property value on type: " & $current.kind)
        {.pop.}

      of IkGenePropsSpread:
        # Spread map key-value pairs into gene properties
        {.push checks: off}
        let value = self.frame.pop()
        let current = self.frame.current()
        case value.kind:
          of VkMap:
            case current.kind:
              of VkGene:
                for k, v in map_data(value):
                  current.gene.props[k] = v
              of VkFrame:
                if current.ref.frame.args.kind != VkGene:
                  current.ref.frame.args = new_gene_value()
                for k, v in map_data(value):
                  current.ref.frame.args.gene.props[k] = v
              of VkNativeFrame:
                discard
              else:
                not_allowed("... can only spread maps into gene properties, got " & $current.kind)
          of VkNil:
            # Spreading nil is a no-op (treat as empty map)
            discard
          else:
            not_allowed("... can only spread maps in gene properties context, got " & $value.kind)
        {.pop.}

      of IkGeneEnd:
        {.push checks: off}
        let kind = self.frame.current().kind
        case kind:
          of VkFrame:
            let frame = self.frame.current().ref.frame
            when DEBUG_VM:
              echo fmt"  Frame kind = {frame.kind}"
            case frame.kind:
              of FkFunction, FkMethod, FkMacroMethod:
                let f = frame.target.ref.fn
                when DEBUG_VM:
                  echo fmt"  Function name = {f.name}, has compiled body = {f.body_compiled != nil}"
                if f.body_compiled == nil:
                  f.compile()
                  when DEBUG_VM:
                    echo "  After compile, scope_tracker.mappings = ", f.scope_tracker.mappings

                self.pc.inc()
                # Pop the VkFrame value from the stack before switching context
                discard self.frame.pop()
                # Set up caller info and switch to the new frame
                frame.caller_frame = self.frame
                self.frame.ref_count.inc()  # Increment ref count since we're storing a reference
                frame.caller_address = Address(cu: self.cu, pc: self.pc)
                frame.ns = f.ns
                
                # Profile function entry
                if self.profiling:
                  let func_name = if f.name != "": f.name else: "<anonymous>"
                  self.enter_function(func_name)
                
                self.frame = frame
                self.cu = f.body_compiled
                
                # Process arguments if matcher exists
                when DEBUG_VM:
                  echo "  Matcher empty? ", f.matcher.is_empty(), ", matcher.children.len = ", f.matcher.children.len
                  if not f.matcher.is_empty():
                    echo "  frame.args = ", frame.args
                if not f.matcher.is_empty():
                  # For methods, the matcher includes self as a parameter
                  # So we should pass ALL arguments including self
                  if is_method_frame(frame):
                    process_args(f.matcher, frame.args, frame.scope)
                  elif f.matcher.has_type_annotations:
                    # Type-annotated functions must go through process_args for runtime type validation
                    process_args(f.matcher, frame.args, frame.scope)
                  else:
                    # Optimization: Fast paths for common argument patterns
                    if frame.args.kind == VkGene:
                      let arg_count = frame.args.gene.children.len
                      let param_count = f.matcher.children.len
                      
                      # Zero-argument optimization
                      if arg_count == 0 and param_count == 0:
                        # No arguments to process - skip matcher entirely
                        discard
                      
                      # Single-argument optimization
                      elif arg_count == 1 and param_count == 1:
                        let param = f.matcher.children[0]
                        # Check for simple parameter binding
                        if param.kind == MatchData and not param.is_splat and param.children.len == 0:
                          # Direct assignment - avoid full matcher processing
                          if f.scope_tracker.mappings.has_key(param.name_key):
                            let idx = f.scope_tracker.mappings[param.name_key]
                            while frame.scope.members.len <= idx:
                              frame.scope.members.add(NIL)
                            frame.scope.members[idx] = frame.args.gene.children[0]
                          else:
                            # Fall back to normal processing if we can't find the index
                            process_args(f.matcher, frame.args, frame.scope)
                        else:
                          # Complex matcher - use normal processing
                          process_args(f.matcher, frame.args, frame.scope)
                      
                      # Two-argument optimization
                      elif arg_count == 2 and param_count == 2:
                        when DEBUG_VM:
                          echo "Two-argument optimization: arg_count = ", arg_count, ", param_count = ", param_count
                        let param1 = f.matcher.children[0]
                        let param2 = f.matcher.children[1]
                        # Check for simple parameter bindings
                        if param1.kind == MatchData and not param1.is_splat and param1.children.len == 0 and
                           param2.kind == MatchData and not param2.is_splat and param2.children.len == 0:
                          when DEBUG_VM:
                            echo "  Both params are simple bindings"
                          # Direct assignment for both parameters
                          var all_mapped = true
                          if f.scope_tracker.mappings.has_key(param1.name_key) and
                             f.scope_tracker.mappings.has_key(param2.name_key):
                            let idx1 = f.scope_tracker.mappings[param1.name_key]
                            let idx2 = f.scope_tracker.mappings[param2.name_key]
                            let max_idx = max(idx1, idx2)
                            when DEBUG_VM:
                              echo "  idx1 = ", idx1, ", idx2 = ", idx2
                            while frame.scope.members.len <= max_idx:
                              frame.scope.members.add(NIL)
                            when DEBUG_VM:
                              echo "  Setting args: [0] = ", frame.args.gene.children[0], " [1] = ", frame.args.gene.children[1]
                            frame.scope.members[idx1] = frame.args.gene.children[0]
                            frame.scope.members[idx2] = frame.args.gene.children[1]
                          else:
                            # Fall back if we can't find indices
                            process_args(f.matcher, frame.args, frame.scope)
                        else:
                          # Complex matcher - use normal processing
                          process_args(f.matcher, frame.args, frame.scope)
                      
                      else:
                        # Regular function call - 3+ args or mismatched counts
                        process_args(f.matcher, frame.args, frame.scope)
                    else:
                      # Non-gene args - use normal processing
                      process_args(f.matcher, frame.args, frame.scope)
                
                # If this is an async function, set up exception handler
                if f.async:
                  self.exception_handlers.add(ExceptionHandler(
                    catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                    finally_pc: -1,
                    frame: self.frame,
                    scope: self.frame.scope,
                    cu: self.cu,
                    saved_value: NIL,
                    has_saved_value: false,
                    in_finally: false
                  ))
                
                self.pc = 0
                inst = self.cu.instructions[self.pc].addr
                continue

              of FkMacro:
                # Handle macro-like function (VkFunction with is_macro_like=true)
                let f = frame.target.ref.fn
                if f.body_compiled == nil:
                  f.compile()

                self.pc.inc()
                # Pop the VkFrame value from the stack before switching context
                discard self.frame.pop()
                # Set up caller info and switch to the new frame
                frame.caller_frame = self.frame
                self.frame.ref_count.inc()  # Increment ref count since we're storing a reference
                frame.caller_address = Address(cu: self.cu, pc: self.pc)
                frame.ns = f.ns
                self.frame = frame
                self.cu = f.body_compiled

                # Process arguments if matcher exists
                if not f.matcher.is_empty():
                  process_args(f.matcher, frame.args, frame.scope)

                self.pc = 0
                inst = self.cu.instructions[self.pc].addr
                continue

              of FkBlock:
                let b = frame.target.ref.block
                if b.body_compiled == nil:
                  b.compile()

                self.pc.inc()
                # Pop the VkFrame value from the stack before switching context
                discard self.frame.pop()
                # Set up caller info and switch to the new frame
                frame.caller_frame = self.frame
                self.frame.ref_count.inc()  # Increment ref count since we're storing a reference
                frame.caller_address = Address(cu: self.cu, pc: self.pc)
                frame.ns = b.ns
                self.frame = frame
                self.cu = b.body_compiled

                # Process arguments if matcher exists
                if not b.matcher.is_empty():
                  process_args(b.matcher, frame.args, frame.scope)

                self.pc = 0
                inst = self.cu.instructions[self.pc].addr
                continue

              else:
                not_allowed("Unsupported frame kind for gene end: " & $frame.kind)

          of VkNativeFrame:
            let frame = self.frame.current().ref.native_frame
            case frame.kind:
              of NfFunction:
                let f = frame.target.ref.native_fn
                self.frame.replace(call_native_fn(f, self, frame.args.gene.children))
              of NfMethod:
                # Native method call - invoke the native function with self as first arg
                let f = frame.target.ref.native_fn
                self.frame.replace(call_native_fn(f, self, frame.args.gene.children))
              else:
                not_allowed("Unsupported native frame kind: " & $frame.kind)

          else:
            # Check if this is a gene with a generator function as its type
            let value = self.frame.current()
            if value.kind == VkGene and value.gene.type.kind == VkFunction:
              let f = value.gene.type.ref.fn
              if f.is_generator:
                # Create generator instance with the arguments from the gene
                let gen_value = new_generator_value(f, value.gene.children)
                self.frame.replace(gen_value)
              else:
                discard
            elif value.kind == VkGene and value.gene.type.kind == VkNativeFn:
              let f = value.gene.type.ref.native_fn
              self.frame.replace(call_native_fn(f, self, value.gene.children))
            elif value.kind == VkGene and value.gene.type.kind == VkNativeMacro:
              # Native macro receives unevaluated Gene value and caller frame
              let f = value.gene.type.ref.native_macro
              let result = f(self, value, self.frame)
              self.frame.replace(result)
            else:
              discard
          
        {.pop.}

      of IkAdd:
        {.push checks: off}
        let second = self.frame.pop()
        let first = self.frame.pop()
        # when not defined(release):
        #   if self.trace:
        #     echo fmt"IkAdd: first={first} ({first.kind}), second={second} ({second.kind})"
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(first.int64 + second.int64)
              of VkFloat:
                self.frame.push(add_mixed(first.int64, second.float))
              else:
                not_allowed("Cannot add " & $first.kind & " and " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                let r = add_mixed(second.int64, first.float)
                when not defined(release):
                  if self.trace:
                    echo fmt"IkAdd float+int: {first.float} + {second.int64.float64} = {r}"
                self.frame.push(r)
              of VkFloat:
                self.frame.push(add_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot add " & $first.kind & " and " & $second.kind)
          else:
            not_allowed("Cannot add values of type: " & $first.kind)
        {.pop.}

      of IkSub:
        {.push checks: off}
        let second = self.frame.pop()
        let first = self.frame.pop()
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(sub_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.push(sub_mixed(first.int64, second.float))
              else:
                not_allowed("Cannot subtract " & $second.kind & " from " & $first.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(sub_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(sub_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot subtract " & $second.kind & " from " & $first.kind)
          else:
            not_allowed("Cannot subtract from values of type: " & $first.kind)
        {.pop.}
      of IkSubValue:
        {.push checks: off}
        let first = self.frame.current()
        case first.kind:
          of VkInt:
            case inst.arg0.kind:
              of VkInt:
                self.frame.replace(sub_int_fast(first.int64, inst.arg0.int64))
              of VkFloat:
                self.frame.replace(sub_mixed(first.int64, inst.arg0.float))
              else:
                not_allowed("Cannot subtract " & $inst.arg0.kind & " from " & $first.kind)
          of VkFloat:
            case inst.arg0.kind:
              of VkInt:
                self.frame.replace(sub_float_fast(first.float, inst.arg0.int64.float64))
              of VkFloat:
                self.frame.replace(sub_float_fast(first.float, inst.arg0.float))
              else:
                not_allowed("Cannot subtract " & $inst.arg0.kind & " from " & $first.kind)
          else:
            not_allowed("Cannot subtract from values of type: " & $first.kind)
        {.pop.}

      of IkMul:
        {.push checks: off}
        let second = self.frame.pop()
        let first = self.frame.pop()
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(mul_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.push(mul_mixed(first.int64, second.float))
              else:
                not_allowed("Cannot multiply " & $first.kind & " by " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(mul_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(mul_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot multiply " & $first.kind & " by " & $second.kind)
          else:
            not_allowed("Cannot multiply values of type: " & $first.kind)
        {.pop.}

      of IkDiv:
        let second = self.frame.pop()
        let first = self.frame.pop()
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(div_mixed(first.int64, second.int64.float64))
              of VkFloat:
                self.frame.push(div_mixed(first.int64, second.float))
              else:
                not_allowed("Cannot divide " & $first.kind & " by " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(div_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(div_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot divide " & $first.kind & " by " & $second.kind)
          else:
            not_allowed("Cannot divide values of type: " & $first.kind)

      of IkNeg:
        # Unary negation
        let value = self.frame.pop()
        case value.kind:
          of VkInt:
            self.frame.push(neg_int_fast(value.int64))
          of VkFloat:
            self.frame.push(neg_float_fast(value.float))
          else:
            not_allowed("Cannot negate value of type: " & $value.kind)

      of IkVarAddValue:
        {.push checks: off}
        # Get variable value based on parent index (stored in arg1)
        let var_value = if inst.arg1 == 0:
          self.frame.scope.members[inst.arg0.int64]
        else:
          var scope = self.frame.scope
          for _ in 0..<inst.arg1:
            scope = scope.parent
          scope.members[inst.arg0.int64]
        
        # Get literal value from next instruction
        self.pc.inc()
        inst = self.cu.instructions[self.pc].addr
        let literal_value = inst.arg0
        
        # Add variable and literal
        case var_value.kind:
          of VkInt:
            case literal_value.kind:
              of VkInt:
                self.frame.push(add_int_fast(var_value.int64, literal_value.int64))
              of VkFloat:
                self.frame.push(add_mixed(var_value.int64, literal_value.float))
              else:
                not_allowed("Cannot add " & $var_value.kind & " and " & $literal_value.kind)
          of VkFloat:
            case literal_value.kind:
              of VkInt:
                self.frame.push(add_mixed(literal_value.int64, var_value.float))
              of VkFloat:
                self.frame.push(add_float_fast(var_value.float, literal_value.float))
              else:
                not_allowed("Cannot add " & $var_value.kind & " and " & $literal_value.kind)
          else:
            not_allowed("Cannot add variable of type: " & $var_value.kind)
        {.pop.}

      of IkIncVar:
        {.push checks: off}
        # Increment variable directly without stack operations
        let index = inst.arg0.int64.int
        let current = self.frame.scope.members[index]
        if current.kind == VkInt:
          self.frame.scope.members[index] = (current.int64 + 1).to_value()
          self.frame.push(self.frame.scope.members[index])
        else:
          not_allowed("Cannot increment variable of type: " & $current.kind & " (only integers supported)")
        {.pop.}

      of IkVarSubValue:
        {.push checks: off}
        # Get variable value based on parent index (stored in arg1)
        let var_value = if inst.arg1 == 0:
          self.frame.scope.members[inst.arg0.int64]
        else:
          var scope = self.frame.scope
          for _ in 0..<inst.arg1:
            scope = scope.parent
          scope.members[inst.arg0.int64]
        
        # Get literal value from next instruction
        self.pc.inc()
        inst = self.cu.instructions[self.pc].addr
        let literal_value = inst.arg0
        
        # Subtract literal from variable
        case var_value.kind:
          of VkInt:
            case literal_value.kind:
              of VkInt:
                self.frame.push(sub_int_fast(var_value.int64, literal_value.int64))
              of VkFloat:
                self.frame.push(sub_mixed(var_value.int64, literal_value.float))
              else:
                not_allowed("Cannot subtract " & $literal_value.kind & " from " & $var_value.kind)
          of VkFloat:
            case literal_value.kind:
              of VkInt:
                self.frame.push(sub_float_fast(var_value.float, literal_value.int64.float64))
              of VkFloat:
                self.frame.push(sub_float_fast(var_value.float, literal_value.float))
              else:
                not_allowed("Cannot subtract " & $literal_value.kind & " from " & $var_value.kind)
          else:
            not_allowed("Cannot subtract from variable of type: " & $var_value.kind)
        {.pop.}

      of IkDecVar:
        {.push checks: off}
        # Decrement variable directly without stack operations
        let index = inst.arg0.int64.int
        let current = self.frame.scope.members[index]
        if current.kind == VkInt:
          self.frame.scope.members[index] = (current.int64 - 1).to_value()
          self.frame.push(self.frame.scope.members[index])
        else:
          not_allowed("Cannot decrement variable of type: " & $current.kind & " (only integers supported)")
        {.pop.}

      of IkVarMulValue:
        {.push checks: off}
        # Get variable value based on parent index (stored in arg1)
        let var_value = if inst.arg1 == 0:
          self.frame.scope.members[inst.arg0.int64]
        else:
          var scope = self.frame.scope
          for _ in 0..<inst.arg1:
            scope = scope.parent
          scope.members[inst.arg0.int64]
        
        # Get literal value from next instruction
        self.pc.inc()
        inst = self.cu.instructions[self.pc].addr
        let literal_value = inst.arg0
        
        # Multiply variable by literal
        case var_value.kind:
          of VkInt:
            case literal_value.kind:
              of VkInt:
                self.frame.push(mul_int_fast(var_value.int64, literal_value.int64))
              of VkFloat:
                self.frame.push(var_value.int64.float64 * literal_value.float)
              else:
                not_allowed("Cannot multiply " & $var_value.kind & " by " & $literal_value.kind)
          of VkFloat:
            case literal_value.kind:
              of VkInt:
                self.frame.push(var_value.float * literal_value.int64.float64)
              of VkFloat:
                self.frame.push(var_value.float * literal_value.float)
              else:
                not_allowed("Cannot multiply " & $var_value.kind & " by " & $literal_value.kind)
          else:
            not_allowed("Cannot multiply variable of type: " & $var_value.kind)
        {.pop.}

      of IkVarDivValue:
        {.push checks: off}
        # Get variable value based on parent index (stored in arg1)
        let var_value = if inst.arg1 == 0:
          self.frame.scope.members[inst.arg0.int64]
        else:
          var scope = self.frame.scope
          for _ in 0..<inst.arg1:
            scope = scope.parent
          scope.members[inst.arg0.int64]
        
        # Get literal value from next instruction
        self.pc.inc()
        inst = self.cu.instructions[self.pc].addr
        let literal_value = inst.arg0
        
        # Divide variable by literal
        case var_value.kind:
          of VkInt:
            case literal_value.kind:
              of VkInt:
                self.frame.push(var_value.int64.float64 / literal_value.int64.float64)
              of VkFloat:
                self.frame.push(var_value.int64.float64 / literal_value.float)
              else:
                not_allowed("Cannot divide " & $var_value.kind & " by " & $literal_value.kind)
          of VkFloat:
            case literal_value.kind:
              of VkInt:
                self.frame.push(var_value.float / literal_value.int64.float64)
              of VkFloat:
                self.frame.push(var_value.float / literal_value.float)
              else:
                not_allowed("Cannot divide " & $var_value.kind & " by " & $literal_value.kind)
          else:
            not_allowed("Cannot divide variable of type: " & $var_value.kind)
        {.pop.}

      of IkLt:
        {.push checks: off}
        var second: Value
        self.frame.pop2(second)
        let first = self.frame.current()
        # Use proper comparison based on types
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.replace(lt_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.replace(lt_mixed(first.int64, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " < " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.replace(lt_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.replace(lt_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " < " & $second.kind)
          else:
            not_allowed("Cannot compare " & $first.kind & " < " & $second.kind)
        {.pop.}
      of IkVarLtValue:
        {.push checks: off}
        # Get variable value based on parent index (stored in arg1)
        let var_value = if inst.arg1 == 0:
          self.frame.scope.members[inst.arg0.int64]
        else:
          var scope = self.frame.scope
          for _ in 0..<inst.arg1:
            scope = scope.parent
          scope.members[inst.arg0.int64]
        
        # Get literal value from next instruction
        self.pc.inc()
        inst = self.cu.instructions[self.pc].addr
        let literal_value = inst.arg0
        
        # Compare with literal value
        case var_value.kind:
          of VkInt:
            case literal_value.kind:
              of VkInt:
                self.frame.push(lt_int_fast(var_value.int64, literal_value.int64))
              of VkFloat:
                self.frame.push(lt_mixed(var_value.int64, literal_value.float))
              else:
                not_allowed("Cannot compare " & $var_value.kind & " < " & $literal_value.kind)
          of VkFloat:
            case literal_value.kind:
              of VkInt:
                self.frame.push(lt_float_fast(var_value.float, literal_value.int64.float64))
              of VkFloat:
                self.frame.push(lt_float_fast(var_value.float, literal_value.float))
              else:
                not_allowed("Cannot compare " & $var_value.kind & " < " & $literal_value.kind)
          else:
            not_allowed("Cannot compare " & $var_value.kind & " < " & $literal_value.kind)
        {.pop.}

      of IkVarLeValue, IkVarGtValue, IkVarGeValue, IkVarEqValue:
        {.push checks: off}
        let cmp_kind = inst.kind
        let var_value = if inst.arg1 == 0:
          self.frame.scope.members[inst.arg0.int64]
        else:
          var scope = self.frame.scope
          for _ in 0..<inst.arg1:
            scope = scope.parent
          scope.members[inst.arg0.int64]

        self.pc.inc()
        let data_inst = self.cu.instructions[self.pc].addr
        let literal_value = data_inst.arg0

        template compare(opInt, opFloat, desc: untyped) =
          case var_value.kind:
            of VkInt:
              let leftInt = var_value.to_int()
              case literal_value.kind:
                of VkInt:
                  let rightInt = literal_value.to_int()
                  self.frame.push(opInt(leftInt, rightInt))
                of VkFloat:
                  self.frame.push(opFloat(system.float64(leftInt), literal_value.to_float()))
                else:
                  not_allowed("Cannot compare " & $var_value.kind & " " & desc & " " & $literal_value.kind)
            of VkFloat:
              let leftFloat = var_value.to_float()
              case literal_value.kind:
                of VkInt:
                  self.frame.push(opFloat(leftFloat, system.float64(literal_value.to_int())))
                of VkFloat:
                  self.frame.push(opFloat(leftFloat, literal_value.to_float()))
                else:
                  not_allowed("Cannot compare " & $var_value.kind & " " & desc & " " & $literal_value.kind)
            else:
              not_allowed("Cannot compare " & $var_value.kind & " " & desc & " " & $literal_value.kind)

        case cmp_kind:
          of IkVarLeValue:
            compare(lte_int_fast, lte_float_fast, "<=")
          of IkVarGtValue:
            compare(gt_int_fast, gt_float_fast, ">")
          of IkVarGeValue:
            compare(gte_int_fast, gte_float_fast, ">=")
          of IkVarEqValue:
            compare(eq_int_fast, eq_float_fast, "==")
          else:
            discard
        inst = data_inst
        {.pop.}

      of IkLtValue:
        var first: Value
        self.frame.pop2(first)
        # Use proper comparison based on types
        case first.kind:
          of VkInt:
            case inst.arg0.kind:
              of VkInt:
                self.frame.push(lt_int_fast(first.int64, inst.arg0.int64))
              of VkFloat:
                self.frame.push(lt_mixed(first.int64, inst.arg0.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " < " & $inst.arg0.kind)
          of VkFloat:
            case inst.arg0.kind:
              of VkInt:
                self.frame.push(lt_float_fast(first.float, inst.arg0.int64.float64))
              of VkFloat:
                self.frame.push(lt_float_fast(first.float, inst.arg0.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " < " & $inst.arg0.kind)
          else:
            not_allowed("Cannot compare " & $first.kind & " < " & $inst.arg0.kind)

      of IkLe:
        let second = self.frame.pop()
        let first = self.frame.pop()
        # Use proper comparison based on types
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(lte_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.push(lte_float_fast(first.int64.float64, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " <= " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(lte_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(lte_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " <= " & $second.kind)
          else:
            not_allowed("Cannot compare " & $first.kind & " <= " & $second.kind)

      of IkGt:
        let second = self.frame.pop()
        let first = self.frame.pop()
        # Use proper comparison based on types
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(gt_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.push(gt_float_fast(first.int64.float64, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " > " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(gt_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(gt_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " > " & $second.kind)
          else:
            not_allowed("Cannot compare " & $first.kind & " > " & $second.kind)

      of IkGe:
        let second = self.frame.pop()
        let first = self.frame.pop()
        # Use proper comparison based on types
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(gte_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.push(gte_float_fast(first.int64.float64, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " >= " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(gte_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(gte_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot compare " & $first.kind & " >= " & $second.kind)
          else:
            not_allowed("Cannot compare " & $first.kind & " >= " & $second.kind)

      of IkEq:
        let second = self.frame.pop()
        let first = self.frame.pop()
        # Use fast path for numeric types
        if first.kind == VkInt and second.kind == VkInt:
          self.frame.push(eq_int_fast(first.int64, second.int64))
        elif first.kind == VkFloat and second.kind == VkFloat:
          self.frame.push(eq_float_fast(first.float, second.float))
        else:
          self.frame.push((first == second).to_value())

      of IkNe:
        let second = self.frame.pop()
        let first = self.frame.pop()
        # Use fast path for numeric types
        if first.kind == VkInt and second.kind == VkInt:
          self.frame.push(neq_int_fast(first.int64, second.int64))
        elif first.kind == VkFloat and second.kind == VkFloat:
          self.frame.push(neq_float_fast(first.float, second.float))
        else:
          self.frame.push((first != second).to_value())

      of IkAnd:
        let second = self.frame.pop()
        let first = self.frame.pop()
        if first.to_bool:
          self.frame.push(second)
        else:
          self.frame.push(first)

      of IkOr:
        let second = self.frame.pop()
        let first = self.frame.pop()
        if first.to_bool:
          self.frame.push(first)
        else:
          self.frame.push(second)

      of IkNot:
        let value = self.frame.pop()
        if value.to_bool:
          self.frame.push(FALSE)
        else:
          self.frame.push(TRUE)


      of IkCreateRange:
        let step = self.frame.pop()
        let `end` = self.frame.pop()
        let start = self.frame.pop()
        let range_value = new_range_value(start, `end`, step)
        self.frame.push(range_value)

      of IkCreateEnum:
        let name = self.frame.pop()
        if name.kind != VkString:
          not_allowed("enum name must be a string")
        let enum_def = new_enum(name.str)
        self.frame.push(enum_def.to_value())

      of IkEnumAddMember:
        let value = self.frame.pop()
        let name = self.frame.pop()
        let enum_val = self.frame.current()
        if name.kind != VkString:
          not_allowed("enum member name must be a string")
        if value.kind != VkInt:
          not_allowed("enum member value must be an integer")
        if enum_val.kind != VkEnum:
          not_allowed("can only add members to enums")
        enum_val.add_member(name.str, value.int64.int)

      of IkCompileInit:
        let input = self.frame.pop()
        let compiled = compile_init(input)
        let r = new_ref(VkCompiledUnit)
        r.cu = compiled
        let cu_value = r.to_ref_value()
        self.frame.push(cu_value)

      of IkDefineMethod:
        # Stack: [function]
        let name = inst.arg0
        let fn_value = self.frame.pop()
        
        # The class is passed as the first argument during class initialization
        var class_value: Value
        if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 0:
          class_value = self.frame.args.gene.children[0]
        else:
          # During normal class definition, class should be on stack
          # But we already popped the function, so we can't pop again
          # This is a problem with our current approach
          not_allowed("Cannot find class for method definition")
        
        
        if class_value.kind != VkClass:
          not_allowed("Can only define methods on classes, got " & $class_value.kind)
        
        if fn_value.kind != VkFunction:
          not_allowed("Method value must be a function")
        
        # Access the class - VkClass should always be a reference value
        let class = class_value.ref.class
        let m = Method(
          name: name.str,
          callable: fn_value,
          class: class,
        )
        class.methods[name.str.to_key()] = m
        class.version.inc()
        
        # Set the function's namespace to the class namespace
        fn_value.ref.fn.ns = class.ns
        
        # Return the method
        let r = new_ref(VkMethod)
        r.`method` = m
        self.frame.push(r.to_ref_value())
      
      of IkDefineConstructor:
        # Stack: [function]
        let fn_value = self.frame.pop()
        
        # The class is passed as the first argument during class initialization
        let class_value = if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 0:
          self.frame.args.gene.children[0]
        else:
          self.frame.current()  # Fallback to what's on stack
        
        if class_value.kind != VkClass:
          not_allowed("Can only define constructor on classes, got " & $class_value.kind)
        
        if fn_value.kind != VkFunction:
          not_allowed("Constructor value must be a function")
        
        # Access the class
        let class = class_value.ref.class

        let is_macro_ctor = fn_value.ref.fn.is_macro_like

        if class.constructor != NIL:
          if class.has_macro_constructor != is_macro_ctor:
            not_allowed("Class '" & class.name & "' cannot define both ctor and ctor!")
          else:
            not_allowed("Class '" & class.name & "' already has a constructor")
        
        # Set the constructor
        class.constructor = fn_value

        # Set the function's namespace to the class namespace
        fn_value.ref.fn.ns = class.ns

        # Set has_macro_constructor flag based on function type
        class.has_macro_constructor = is_macro_ctor
        
        # Return the function
        self.frame.push(fn_value)
      
      of IkSuper:
        # Push a proxy representing the parent class for super calls
        let instance = current_self_value(self.frame)
        if instance.kind notin {VkInstance, VkCustom}:
          not_allowed("super requires an instance context")

        let current_class = find_method_class(instance, self.frame.target)
        if current_class == nil or current_class.parent == nil:
          not_allowed("No parent class available for super")

        let super_ref = new_ref(VkSuper)
        super_ref.super_instance = instance
        super_ref.super_class = current_class.parent
        self.frame.push(super_ref.to_ref_value())

      of IkCallInit:
        {.push checks: off}
        let compiled_value = self.frame.pop()
        if compiled_value.kind != VkCompiledUnit:
          raise new_exception(types.Exception, fmt"Expected VkCompiledUnit, got {compiled_value.kind}")
        let compiled = compiled_value.ref.cu
        let obj = self.frame.current()
        var ns: Namespace
        case obj.kind:
          of VkNamespace:
            ns = obj.ref.ns
          of VkClass:
            ns = obj.ref.class.ns
          else:
            not_allowed("Cannot access namespace member on value of type: " & $obj.kind)

        self.pc.inc()
        self.frame = new_frame(self.frame, Address(cu: self.cu, pc: self.pc))
        # Pass the class/namespace as args so methods can access it
        let args_gene = new_gene(NIL)
        args_gene.children.add(obj)
        self.frame.args = args_gene.to_gene_value()
        self.frame.ns = ns
        # when not defined(release):
        #   echo "IkCallInit: switching to init CU, obj kind: ", obj.kind
        #   echo "  New frame has no self field anymore"
        #   echo "  Init CU has ", compiled.instructions.len, " instructions"
        self.cu = compiled
        self.pc = 0
        inst = self.cu.instructions[self.pc].addr
        continue
        {.pop.}

      of IkFunction:
        {.push checks: off}
        let info = to_function_def_info(inst.arg0)
        let f = to_function(info.input)
        
        # Determine the target namespace for the function
        var target_ns = self.frame.ns
        if info.input.kind == VkGene and info.input.gene.children.len > 0:
          let first = info.input.gene.children[0]
          case first.kind:
            of VkComplexSymbol:
              # n/m/f - function should belong to the target namespace
              # Skip if first part is empty (e.g., /method_name becomes ["", "method_name"])
              if first.ref.csymbol.len > 0 and first.ref.csymbol[0] != "":
                for i in 0..<first.ref.csymbol.len - 1:
                  let part = first.ref.csymbol[i]
                  if part == "":
                    continue  # Skip empty parts
                  if part == "$ns" and i == 0:
                    continue  # $ns means current namespace, already set
                  let key = part.to_key()
                  if target_ns.has_key(key):
                    let nsval = target_ns[key]
                    if nsval.kind == VkNamespace:
                      target_ns = nsval.ref.ns
                    else:
                      raise new_exception(types.Exception, fmt"{part} is not a namespace")
                  else:
                    raise new_exception(types.Exception, fmt"Namespace {part} not found")
            else:
              discard
        
        f.ns = target_ns
        # Capture parent scope with proper reference counting
        if self.frame.scope != nil:
          self.frame.scope.ref_count.inc()
          # Function captured scope, ref_count incremented
        f.parent_scope = self.frame.scope

        var scope_tracker_obj: ScopeTracker = nil
        let data_value = inst.arg0

        case data_value.kind
        of VkFunctionDef:
          let info = to_function_def_info(data_value)
          if f.name == "__init__":
            scope_tracker_obj = copy_scope_tracker(info.scope_tracker)
          else:
            scope_tracker_obj = new_scope_tracker(info.scope_tracker)
          if info.compiled_body.kind == VkCompiledUnit:
            f.body_compiled = info.compiled_body.ref.cu
            # Store input back to function for reflection (already parsed above)
        of VkScopeTracker:
          scope_tracker_obj = new_scope_tracker(data_value.ref.scope_tracker)
        else:
          scope_tracker_obj = ScopeTracker()

        if scope_tracker_obj == nil:
          scope_tracker_obj = ScopeTracker()

        f.scope_tracker = scope_tracker_obj
        if not f.matcher.is_empty():
          for child in f.matcher.children:
            if not f.scope_tracker.mappings.hasKey(child.name_key):
              f.scope_tracker.add(child.name_key)

        let r = new_ref(VkFunction)
        r.fn = f
        let v = r.to_ref_value()

        var define_in_ns = true
        if info.input.kind == VkGene and info.input.gene != nil:
          let local_key = "local_def".to_key()
          if info.input.gene.props.has_key(local_key) and info.input.gene.props[local_key] == TRUE:
            define_in_ns = false
          if info.input.gene.children.len > 0 and info.input.gene.children[0].kind == VkArray:
            define_in_ns = false
        
        # Handle namespaced function definitions
        if define_in_ns:
          if info.input.kind == VkGene and info.input.gene.children.len > 0:
            let first = info.input.gene.children[0]
            case first.kind:
            of VkComplexSymbol:
              # n/m/f or $ns/f - define in target namespace
              var ns = self.frame.ns
              for i in 0..<first.ref.csymbol.len - 1:
                let part = first.ref.csymbol[i]
                if part == "":
                  continue  # Skip empty parts
                if part == "$ns" and i == 0:
                  continue  # $ns means current namespace, already set
                let key = part.to_key()
                if ns.has_key(key):
                  let nsval = ns[key]
                  if nsval.kind == VkNamespace:
                    ns = nsval.ref.ns
                  else:
                    raise new_exception(types.Exception, fmt"{part} is not a namespace")
                else:
                  raise new_exception(types.Exception, fmt"Namespace {part} not found")
              ns[f.name.to_key()] = v
            else:
              # Simple name - define in current namespace
              f.ns[f.name.to_key()] = v
          else:
            # Fallback for other cases
            f.ns[f.name.to_key()] = v
        
        self.frame.push(v)
        {.pop.}

      of IkBlock:
        {.push checks: off}
        let info = to_function_def_info(inst.arg0)
        let b = to_block(info.input)
        b.frame = self.frame
        b.ns = self.frame.ns
        b.frame.update(self.frame)
        b.scope_tracker = new_scope_tracker(info.scope_tracker)

        if not b.matcher.is_empty():
          for child in b.matcher.children:
            b.scope_tracker.add(child.name_key)

        let r = new_ref(VkBlock)
        r.block = b
        let v = r.to_ref_value()
        self.frame.push(v)
        {.pop.}

      of IkReturn:
        {.push checks: off}
        # Check if we're in a finally block first
        var in_finally = false
        if self.exception_handlers.len > 0:
          let handler = self.exception_handlers[^1]
          if handler.in_finally:
            in_finally = true
        
        if in_finally:
          # Pop the value that return would have used
          if self.frame.stack_index > 0:
            discard self.frame.pop()
          # Silently ignore return in finally block
          discard
        elif self.frame.caller_frame == nil:
          not_allowed("Return from top level")
        else:
          var v = self.frame.pop()
          
          # Check if we're returning from a function called by exec_function
          let returning_from_exec_function = self.frame.from_exec_function
          
          # Check if we're returning from an async function
          if is_function_like(self.frame.kind) and self.frame.target.kind == VkFunction:
            let f = self.frame.target.ref.fn
            if f.async:
              # Remove the async function exception handler
              if self.exception_handlers.len > 0 and self.exception_handlers[^1].catch_pc == CATCH_PC_ASYNC_FUNCTION:
                discard self.exception_handlers.pop()
              
              # Wrap the return value in a future
              let future_val = new_future_value()
              let future_obj = future_val.ref.future
              future_obj.complete(v)
              v = future_val
          
          # Profile function exit
          if self.profiling:
            self.exit_function()

          # Ensure exception handlers for this frame are cleared on return.
          let returning_frame = self.frame
          self.pop_frame_exception_handlers(returning_frame)
          if self.current_exception != NIL:
            self.current_exception = NIL
          
          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()  # The frame's ref_count was incremented unnecessarily.
          if not returning_from_exec_function:
            self.frame.push(v)
          
          # If we were in exec_function, stop the exec loop by returning
          if returning_from_exec_function:
            result = v
            return result
          
          continue
        {.pop.}
      
      of IkYield:
        # Yield is only valid inside generator functions
        if self.frame.is_generator and self.current_generator != nil:
          
          # Pop the value to yield
          let yielded_value = if self.frame.stack_index > 0:
            self.frame.pop()
          else:
            NIL
          
          # Save generator state
          let gen = self.current_generator
          # Skip past the yield instruction
          # Check if the next instruction is Pop and skip it too
          var next_pc = self.pc + 1
          if next_pc < self.cu.instructions.len and 
             self.cu.instructions[next_pc].kind == IkPop:
            next_pc += 1  # Skip the Pop that follows yield
          
          
          gen.pc = next_pc
          gen.frame = self.frame
          gen.cu = self.cu  # Save the compilation unit
          
          
          # Return the yielded value from exec
          return yielded_value
        else:
          # Not in a generator context - this is an error
          raise new_exception(types.Exception, "yield used outside of generator function")

      of IkNamespace:
        let name = inst.arg0
        var parent_ns: Namespace = nil

        let flags = inst.arg1
        let has_container = (flags and 1) != 0
        let local_def = (flags and 2) != 0

        # Check if we have a container (for nested namespaces like app/models)
        if has_container:
          let container_value = self.frame.pop()
          if container_value.kind == VkNil:
            not_allowed("Cannot create nested namespace '" & name.str & "': parent namespace not found. Did you forget to create the parent namespace first?")
          parent_ns = namespace_from_value(container_value)

        # Create the namespace
        let ns = new_namespace(name.str)
        let r = new_ref(VkNamespace)
        r.ns = ns
        let v = r.to_ref_value()

        # Store in appropriate parent unless local-only
        if not local_def:
          if parent_ns != nil:
            parent_ns[cast[Key](name.raw)] = v
          else:
            self.frame.ns[cast[Key](name.raw)] = v

        self.frame.push(v)

      of IkImport:
        let import_gene = self.frame.pop()
        if import_gene.kind != VkGene:
          not_allowed("Import expects a gene, got " & $import_gene.kind)
        
        let (module_path, imports, module_ns, is_native, handled) = self.handle_import(import_gene.gene)
        
        if handled:
          self.frame.push(NIL)
          continue
        
        # If module is not cached, we need to execute it
        if not ModuleCache.hasKey(module_path):
          if is_native:
            # Load native extension
            when not defined(noExtensions):
              let ext_ns = load_extension(self, module_path)
              ModuleCache[module_path] = ext_ns
              
              # Import requested symbols
              self.import_items(ext_ns, imports)
            else:
              not_allowed("Native extensions are not supported in this build")
          else:
            # Cycle detection
            if ModuleLoadState.getOrDefault(module_path, false):
              var cycle: seq[string] = @[]
              var start = -1
              for i, entry in ModuleLoadStack:
                if entry == module_path:
                  start = i
                  break
              if start >= 0:
                cycle = ModuleLoadStack[start..^1] & @[module_path]
              else:
                cycle = ModuleLoadStack & @[module_path]
              not_allowed("Cyclic import detected: " & cycle.join(" -> "))

            ModuleLoadState[module_path] = true
            ModuleLoadStack.add(module_path)

            # Compile the module
            try:
              let cu = compile_module(module_path)
              
              # Save current state
              let saved_cu = self.cu
              let saved_frame = self.frame
              let saved_pc = self.pc

              # Create a new frame for module execution
              self.frame = new_frame()
              self.frame.ns = module_ns
              # Module namespace is now passed as argument, not stored as self
              let args_gene = new_gene(NIL)
              args_gene.children.add(module_ns.to_value())
              self.frame.args = args_gene.to_gene_value()
              
              # Execute the module
              self.cu = cu
              discard self.exec()
              discard self.run_module_init(module_ns)
              
              # Restore the original state
              self.cu = saved_cu
              self.frame = saved_frame
              self.pc = saved_pc
              
              # Cache the module
              ModuleCache[module_path] = module_ns
              
              # Import requested symbols
              self.import_items(module_ns, imports)
            finally:
              if ModuleLoadState.hasKey(module_path):
                ModuleLoadState.del(module_path)
              if ModuleLoadStack.len > 0 and ModuleLoadStack[^1] == module_path:
                ModuleLoadStack.setLen(ModuleLoadStack.len - 1)
        else:
          # Module already cached - import requested symbols
          let cached_ns = ModuleCache[module_path]
          self.import_items(cached_ns, imports)

        self.frame.push(NIL)

      of IkExport:
        let export_list = inst.arg0
        if export_list.kind != VkArray:
          not_allowed("export expects an array of names")
        if self.frame == nil or self.frame.ns == nil:
          not_allowed("export requires an active module namespace")

        for item in array_data(export_list):
          var name = ""
          case item.kind
          of VkSymbol, VkString:
            name = item.str
          else:
            not_allowed("export names must be symbols or strings")
          if name.len == 0:
            continue
          let resolved = self.resolve_local_or_namespace(name)
          if not resolved.found:
            not_allowed("Cannot export '" & name & "': value not found")
          self.frame.ns.members[name.to_key()] = resolved.value
          add_export(self.frame.ns, name)

        self.frame.push(NIL)

      of IkNamespaceStore:
        let value = self.frame.pop()
        let name = inst.arg0
        self.frame.ns[name.str.to_key()] = value
        self.frame.push(value)
      
      of IkClass:
        let name = inst.arg0
        var class_name: string
        var target_ns = self.frame.ns
        var class_key: Key
        let flags = inst.arg1
        let has_container = (flags and 1) != 0
        let local_def = (flags and 2) != 0
        if has_container:
          let container_value = self.frame.pop()
          target_ns = namespace_from_value(container_value)
        case name.kind
        of VkSymbol:
          class_name = name.str
          class_key = name.str.to_key()
        of VkString:
          class_name = name.str
          class_key = name.str.to_key()
        of VkComplexSymbol:
          if name.ref.csymbol.len == 0:
            not_allowed("Class name cannot be an empty path")
          class_name = name.ref.csymbol[^1]
          class_key = class_name.to_key()
          if name.ref.csymbol.len > 1:
            target_ns = ensure_namespace_path(self.frame.ns, name.ref.csymbol, name.ref.csymbol.len - 1)
        else:
          not_allowed("Unsupported class name type: " & $name.kind)

        let class = new_class(class_name)
        # Set the class namespace's parent to the current frame's namespace
        # This allows class bodies to access global symbols like other classes
        class.ns.parent = self.frame.ns
        if not App.is_nil and App.kind == VkApplication:
          let base = App.app.object_class
          if base.kind == VkClass and class.parent.is_nil:
            class.parent = base.ref.class
        class.add_standard_instance_methods()
        let r = new_ref(VkClass)
        r.class = class
        let v = r.to_ref_value()
        if not local_def:
          target_ns.members[class_key] = v
        self.frame.push(v)

      of IkNew:
        # Stack: either [class, args_gene] or just [class]
        var class_val = self.frame.pop()
        var args: Value
        if class_val.kind == VkGene and class_val.gene.type != NIL and class_val.gene.type.kind == VkClass:
          # Legacy path where class is wrapped in a gene; no args provided
          args = new_gene_value()
        elif class_val.kind == VkGene:
          # Top value is the argument gene; grab class next
          args = class_val
          class_val = self.frame.pop()
        else:
          # No explicit arguments were provided
          args = new_gene_value()

        # Get the class
        let class = if class_val.kind == VkClass:
          class_val.ref.class
        elif class_val.kind == VkGene and class_val.gene.type != NIL and class_val.gene.type.kind == VkClass:
          # Legacy path for Gene with type set to class
          class_val.gene.type.ref.class
        else:
          when not defined(release):
            echo "DEBUG IkNew: class_val.kind = ", class_val.kind
            if class_val.kind == VkGene:
              echo "  Gene type = ", class_val.gene.type
          raise new_exception(types.Exception, "new requires a class, got " & $class_val.kind)

        let is_macro_call = inst.arg1 != 0
        if is_macro_call and not class.has_macro_constructor:
          not_allowed("Class '" & class.name & "' defines ctor, use 'new' instead of 'new!'")
        if (not is_macro_call) and class.has_macro_constructor:
          not_allowed("Class '" & class.name & "' defines ctor!, use 'new!' instead of 'new'")
        
        # Check constructor type
        case class.constructor.kind:
          of VkNativeFn:
            # Call native constructor
            if args.kind == VkGene and args.gene.props.len > 0:
              var native_args = newSeq[Value](args.gene.children.len + 1)
              var kw_map = new_map_value()
              for k, v in args.gene.props:
                map_data(kw_map)[k] = v
              native_args[0] = kw_map
              for i, child in args.gene.children:
                native_args[i + 1] = child
              let result = call_native_fn(class.constructor.ref.native_fn, self, native_args, true)
              self.frame.push(result)
            else:
              let result = call_native_fn(class.constructor.ref.native_fn, self, args.gene.children)
              self.frame.push(result)
            
          of VkFunction:
            # Regular function constructor
            let instance = new_instance_value(class)
            self.frame.push(instance)
            
            class.constructor.ref.fn.compile()
            let compiled = class.constructor.ref.fn.body_compiled
            compiled.skip_return = true

            # Create scope for constructor
            let f = class.constructor.ref.fn
            var scope: Scope
            if f.matcher.is_empty():
              scope = f.parent_scope
              # Increment ref_count since the frame will own this reference
              if scope != nil:
                scope.ref_count.inc()
            else:
              scope = new_scope(f.scope_tracker, f.parent_scope)

            self.pc.inc()
            self.frame = new_frame(self.frame, Address(cu: self.cu, pc: self.pc))
            self.frame.kind = if class.has_macro_constructor: FkMacroMethod else: FkMethod
            self.frame.scope = scope  # Set the scope
            self.frame.target = class.constructor
            # Pass instance as first argument for constructor
            let args_gene = new_gene(NIL)
            args_gene.children.add(instance)
            # Add other arguments if present
            if args.kind == VkGene:
              for child in args.gene.children:
                args_gene.children.add(child)
            self.frame.args = args_gene.to_gene_value()
            self.frame.ns = class.constructor.ref.fn.ns
            
            # Process arguments if matcher exists  
            if not f.matcher.is_empty():
              # For constructors, we need to process args without the instance (first arg)
              var constructor_args = new_gene(NIL)
              if args.kind == VkGene:
                for child in args.gene.children:
                  constructor_args.children.add(child)
                for k, v in args.gene.props:
                  constructor_args.props[k] = v
              process_args(f.matcher, constructor_args.to_gene_value(), scope)
              assign_property_params(f.matcher, scope, instance)
            
            self.cu = compiled
            self.pc = 0
            inst = self.cu.instructions[self.pc].addr
            continue
            
          of VkNil:
            # No constructor - create empty instance
            let instance = new_instance_value(class)
            self.frame.push(instance)

          else:
            not_allowed("Unsupported constructor type: " & $class.constructor.kind)

      of IkSubClass:
        let name = inst.arg0
        var class_name: string
        var target_ns = self.frame.ns
        var class_key: Key
        let flags = inst.arg1
        let has_container = (flags and 1) != 0
        let local_def = (flags and 2) != 0
        if has_container:
          let container_value = self.frame.pop()
          target_ns = namespace_from_value(container_value)
        case name.kind
        of VkSymbol:
          class_name = name.str
          class_key = name.str.to_key()
        of VkString:
          class_name = name.str
          class_key = name.str.to_key()
        of VkComplexSymbol:
          if name.ref.csymbol.len == 0:
            not_allowed("Class name cannot be an empty path")
          class_name = name.ref.csymbol[^1]
          class_key = class_name.to_key()
          if name.ref.csymbol.len > 1:
            target_ns = ensure_namespace_path(self.frame.ns, name.ref.csymbol, name.ref.csymbol.len - 1)
        else:
          not_allowed("Unsupported class name type: " & $name.kind)

        let parent_class = self.frame.pop()
        let class = new_class(class_name)
        if parent_class.kind == VkClass:
          class.parent = parent_class.ref.class
          # Inherit parent class namespace to access class members (and module via parent)
          class.ns.parent = class.parent.ns
        else:
          not_allowed("Parent must be a class, got " & $parent_class.kind)
        let r = new_ref(VkClass)
        r.class = class
        let v = r.to_ref_value()
        if not local_def:
          target_ns.members[class_key] = v
        self.frame.push(v)

      of IkResolveMethod:
        # Peek at the object without popping it
        let v = self.frame.current()
        let method_name = inst.arg0.str
        
        let class = v.get_class()
        var cache: ptr InlineCache
        if self.pc < self.cu.inline_caches.len:
          cache = self.cu.inline_caches[self.pc].addr
        else:
          while self.cu.inline_caches.len <= self.pc:
            self.cu.inline_caches.add(InlineCache())
          cache = self.cu.inline_caches[self.pc].addr

        var meth: Method
        if cache.class != nil and cache.class == class and cache.class_version == class.version and cache.cached_method != nil:
          meth = cache.cached_method
        else:
          meth = class.get_method(method_name)
          if meth == nil:
            not_allowed("Method '" & method_name & "' not found on " & $v.kind)
          cache.class = class
          cache.class_version = class.version
          cache.cached_method = meth

        # Push the method callable on top of the object
        self.frame.push(meth.callable)

      of IkThrow:
        {.push checks: off}
        # Pop value from stack if there is one, otherwise use NIL
        let value = self.frame.pop()
        if self.dispatch_exception(value, inst):
          continue
        {.pop.}
        
      of IkTryStart:
        {.push checks: off}
        # arg0 contains the catch PC
        let catch_pc = inst.arg0.int64.int
        # arg1 contains the finally PC (if present)
        let finally_pc = if inst.arg1 != 0: inst.arg1.int else: -1
        when not defined(release):
          if self.trace:
            echo "  TryStart: catch_pc=", catch_pc, ", finally_pc=", finally_pc
        
        self.exception_handlers.add(ExceptionHandler(
          catch_pc: catch_pc,
          finally_pc: finally_pc,
          frame: self.frame,
          scope: self.frame.scope,
          cu: self.cu,
          in_finally: false
        ))
        {.pop.}
        
      of IkTryEnd:
        # Pop exception handler since we exited try block normally
        if self.exception_handlers.len > 0:
          discard self.exception_handlers.pop()
        
      of IkCatchStart:
        # We're in a catch block
        # TODO: Make exception available as $ex variable
        discard
        
      of IkCatchEnd:
        # Don't pop the exception handler yet if there's a finally block
        # It will be popped after the finally block completes
        # Clear current exception
        self.current_exception = NIL
        if self.exception_handlers.len > 0:
          let handler = self.exception_handlers[^1]
          if handler.finally_pc == -1:
            discard self.exception_handlers.pop()
        
      of IkFinally:
        # Finally block execution
        # Save the current stack value if there is one (from try/catch block)
        if self.exception_handlers.len > 0:
          var handler = self.exception_handlers[^1]
          # Mark that we're in a finally block
          handler.in_finally = true
          # Only save value if we're not coming from an exception
          if self.current_exception == NIL and self.frame.stack_index > 0:
            handler.saved_value = self.frame.pop()
            handler.has_saved_value = true
            self.exception_handlers[^1] = handler
            when not defined(release):
              if self.trace:
                echo "  Finally: saved value ", handler.saved_value
          else:
            handler.has_saved_value = false
            self.exception_handlers[^1] = handler
        when not defined(release):
          if self.trace:
            echo "  Finally: starting finally block"
      
      of IkFinallyEnd:
        # End of finally block
        # Pop any value left by the finally block
        if self.frame.stack_index > 0:
          discard self.frame.pop()
        
        # Restore saved value if we have one and reset in_finally flag
        if self.exception_handlers.len > 0:
          var handler = self.exception_handlers[^1]
          handler.in_finally = false
          self.exception_handlers[^1] = handler
          if handler.has_saved_value:
            self.frame.push(handler.saved_value)
            when not defined(release):
              if self.trace:
                echo "  FinallyEnd: restored value ", handler.saved_value
        
        # Now we can pop the exception handler
        if self.exception_handlers.len > 0:
          discard self.exception_handlers.pop()
        
        when not defined(release):
          if self.trace:
            echo "  FinallyEnd: current_exception = ", self.current_exception
        
        if self.current_exception != NIL:
          # Re-throw the exception
          let value = self.current_exception
          self.current_exception = NIL  # Clear before rethrowing

          if self.dispatch_exception(value, inst):
            continue

      of IkGetClass:
        # Get the class of a value
        {.push checks: off}
        let value = self.frame.pop()
        var class_val: Value
        
        case value.kind
        of VkNil:
          class_val = App.app.nil_class
        of VkBool:
          class_val = App.app.bool_class
        of VkInt:
          class_val = App.app.int_class
        of VkFloat:
          class_val = App.app.float_class
        of VkChar:
          class_val = App.app.char_class
        of VkString:
          class_val = App.app.string_class
        of VkSymbol:
          class_val = App.app.symbol_class
        of VkComplexSymbol:
          class_val = App.app.complex_symbol_class
        of VkArray:
          class_val = App.app.array_class
        of VkMap:
          class_val = App.app.map_class
        of VkGene:
          class_val = App.app.gene_class
        of VkSet:
          class_val = App.app.set_class
        of VkTime:
          class_val = App.app.time_class
        of VkDate:
          class_val = App.app.date_class
        of VkDateTime:
          class_val = App.app.datetime_class
        of VkClass:
          if value.ref.class.parent != nil:
            let parent_ref = new_ref(VkClass)
            parent_ref.class = value.ref.class.parent
            class_val = parent_ref.to_ref_value()
          else:
            class_val = App.app.object_class
        of VkInstance:
          # Get the class of the instance
          let instance_class_ref = new_ref(VkClass)
          instance_class_ref.class = instance_class(value)
          class_val = instance_class_ref.to_ref_value()
        of VkCustom:
          if value.ref.custom_class != nil:
            let custom_class_ref = new_ref(VkClass)
            custom_class_ref.class = value.ref.custom_class
            class_val = custom_class_ref.to_ref_value()
          else:
            class_val = App.app.object_class
        of VkApplication:
          # Applications don't have a specific class
          class_val = App.app.object_class
        else:
          # For all other types, use the Object class
          class_val = App.app.object_class
        
        self.frame.push(class_val)
        {.pop.}
      
      of IkIsInstance:
        # Check if a value is an instance of a class (including inheritance)
        {.push checks: off}
        let expected_class = self.frame.pop()
        let value = self.frame.pop()
        
        var is_instance = false
        var actual_class: Class
        
        # Get the actual class of the value
        case value.kind
        of VkInstance:
          actual_class = instance_class(value)
        of VkCustom:
          actual_class = value.ref.custom_class
        of VkClass:
          actual_class = value.ref.class
        else:
          # For primitive types, we would need to check against their built-in classes
          # For now, just return false
          self.frame.push(false.to_value())
          continue
        
        # Check if expected_class is a class
        if expected_class.kind != VkClass:
          self.frame.push(false.to_value())
          continue
        
        let expected = expected_class.ref.class
        
        # Check direct match first
        if actual_class == expected:
          is_instance = true
        else:
          # Check inheritance chain
          var current = actual_class
          while current.parent != nil:
            if current.parent == expected:
              is_instance = true
              break
            current = current.parent
        
        self.frame.push(is_instance.to_value())
        {.pop.}
      
      of IkCatchRestore:
        # Restore the current exception for the next catch clause
        {.push checks: off}
        if self.exception_handlers.len > 0:
          # Push the current exception back onto the stack for the next catch
          self.frame.push(self.current_exception)
        {.pop.}
      
      of IkCallerEval:
        # Evaluate expression in caller's context
        {.push checks: off}
        let expr = self.frame.pop()
        
        # We need to be in a macro context (or function called as macro) to use $caller_eval
        # Check current frame first, then check if any parent frame has caller_context
        var current_frame = self.frame
        while current_frame != nil:
          if current_frame.caller_context != nil:
            break
          current_frame = current_frame.caller_frame

        if current_frame == nil or current_frame.caller_context == nil:
          not_allowed("$caller_eval can only be used within macros or macro-like functions")
        
        # Get the caller's context from the frame that has it
        let caller_frame = current_frame.caller_context
        
        # The expression might be a quoted symbol like `a
        # We need to evaluate it, not compile the quote itself
        var expr_to_eval = expr
        if expr.kind == VkQuote:
          expr_to_eval = expr.ref.quote
        
        # Evaluate the expression in the caller's context
        # For now, we'll handle simple cases directly
        case expr_to_eval.kind:
          of VkSymbol:
            # Direct symbol evaluation in caller's context
            let symbol_str = expr_to_eval.str
            if symbol_str.starts_with("$") and symbol_str.len > 1:
              if symbol_str == "$ns":
                let ns_ref = new_ref(VkNamespace)
                ns_ref.ns = caller_frame.ns
                self.frame.push(ns_ref.to_ref_value())
              elif symbol_str == "$ex":
                let ex_value = if self.current_exception != NIL: self.current_exception else: self.repl_exception
                self.frame.push(ex_value)
              else:
                let key = symbol_str[1..^1].to_key()
                let resolved = App.app.global_ns.ref.ns[key]
                if resolved == NIL:
                  not_allowed("Unknown symbol in caller context: " & symbol_str)
                self.frame.push(resolved)
            else:
              let key = symbol_str.to_key()
              var r = NIL

              # First check if it's a local variable in the caller's scope
              if caller_frame.scope != nil and caller_frame.scope.tracker != nil:
                let found = caller_frame.scope.tracker.locate(key)
                if found.local_index >= 0:
                  # Variable found in scope
                  var scope = caller_frame.scope
                  var parent_index = found.parent_index
                  while parent_index > 0:
                    parent_index.dec()
                    scope = scope.parent
                  if found.local_index < scope.members.len:
                    r = scope.members[found.local_index]

              if r == NIL:
                # Not a local variable, look in namespaces
                r = if caller_frame.ns != nil: caller_frame.ns[key] else: NIL
                if r == NIL and self.thread_local_ns != nil:
                  r = self.thread_local_ns[key]
                if r == NIL:
                  not_allowed("Unknown symbol in caller context: " & symbol_str)

              self.frame.push(r)

          of VkInt, VkFloat, VkString, VkBool, VkNil, VkChar:
            # For literals, no evaluation needed - just return as-is
            self.frame.push(expr_to_eval)

          else:
            # For complex expressions, compile and execute
            # This will have issues with local variables, but at least handles globals
            let compiled = compile_init(expr_to_eval)

            # Save current state
            let saved_frame = self.frame
            let saved_cu = self.cu
            let saved_pc = self.pc

            # Create a new frame for evaluation
            # Link caller_frame to macro frame so exception handlers can unwind correctly
            let eval_frame = new_frame()
            eval_frame.caller_frame = self.frame
            self.frame.ref_count.inc()  # Increment since we're storing a reference
            eval_frame.ns = caller_frame.ns
            # Copy caller_context so nested $caller_eval calls work
            if current_frame != nil and current_frame.caller_context != nil:
              eval_frame.caller_context = current_frame.caller_context
            # Copy args and scope from caller
            eval_frame.args = caller_frame.args
            eval_frame.scope = caller_frame.scope
            # Mark this so IkEnd knows to return
            eval_frame.from_exec_function = true

            # Switch to evaluation context
            self.frame = eval_frame
            self.cu = compiled

            # Execute in caller's context
            let r = self.exec()

            # Restore macro context
            self.frame = saved_frame
            self.cu = saved_cu
            self.pc = saved_pc
            inst = self.cu.instructions[self.pc].addr

            # Push r back to macro's stack
            self.frame.push(r)
        {.pop.}
      
      of IkAsyncStart:
        # Start of async block - push a special marker
        {.push checks: off}
        # Add an exception handler that will catch exceptions for the async block
        self.exception_handlers.add(ExceptionHandler(
          catch_pc: CATCH_PC_ASYNC_BLOCK,  # Special marker for async
          finally_pc: -1,
          frame: self.frame,
          scope: self.frame.scope,
          cu: self.cu,
          saved_value: NIL,
          has_saved_value: false,
          in_finally: false
        ))
        {.pop.}
      
      of IkAsyncEnd:
        # End of async block - wrap result in future
        {.push checks: off}
        let value = self.frame.pop()
        
        # Remove the async exception handler
        if self.exception_handlers.len > 0:
          discard self.exception_handlers.pop()
        
        # Create a new Future
        let future_val = new_future_value()
        let future_obj = future_val.ref.future
        
        # Complete the future with the value
        future_obj.complete(value)
        
        self.frame.push(future_val)
        {.pop.}
      
      of IkAsync:
        # Legacy instruction - just wrap value in future
        {.push checks: off}
        let value = self.frame.pop()
        let future_val = new_future_value()
        let future_obj = future_val.ref.future
        
        if value.kind == VkException:
          future_obj.fail(value)
        else:
          future_obj.complete(value)
        
        self.frame.push(future_val)
        {.pop.}
      
      of IkAwait:
        # Wait for a Future to complete
        {.push checks: off}
        let future_val = self.frame.pop()

        if future_val.kind != VkFuture:
          not_allowed("await expects a Future, got: " & $future_val.kind)
        
        let future = future_val.ref.future
        
        # Check the future state and handle accordingly
        case future.state:
          of FsSuccess:
            self.frame.push(future.value)
          of FsFailure:
            # Re-throw the exception stored in the future
            self.current_exception = future.value
            # Look for exception handler (same logic as IkThrow)
            if self.exception_handlers.len > 0:
              let handler = self.exception_handlers[^1]
              # Jump to catch block
              self.cu = handler.cu
              self.pc = handler.catch_pc
              if self.pc < self.cu.instructions.len:
                inst = self.cu.instructions[self.pc].addr
              else:
                raise new_exception(types.Exception, "Invalid catch PC: " & $self.pc)
              continue
            else:
              # No handler, raise Nim exception
              raise new_exception(types.Exception, self.format_runtime_exception(future.value))
          of FsPending:
            # Poll event loop until future completes
            # Callbacks will update the future state when async operations complete
            while future.state == FsPending:
              # Check for thread replies (non-blocking)
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
                          future_obj.state = FsFailure
                          future_obj.value = wrap_nim_exception(ex, "thread reply decode")
                          self.thread_futures.del(msg.from_message_id)
                          continue
                      let error_msg = thread_error_message(payload)
                      if error_msg.len > 0:
                        let ex = new_exception(types.Exception, error_msg)
                        future_obj.state = FsFailure
                        future_obj.value = wrap_nim_exception(ex, "thread reply")
                        if future_obj.nim_future != nil and not future_obj.nim_future.finished:
                          future_obj.nim_future.fail(newException(system.Exception, error_msg))
                        self.thread_futures.del(msg.from_message_id)
                        continue
                      future_obj.state = FsSuccess
                      future_obj.value = payload
                      self.thread_futures.del(msg.from_message_id)

              # Poll the event loop to process async operations and fire callbacks
              try:
                if hasPendingOperations():
                  poll(0)  # Process ready operations
              except ValueError:
                discard  # No async operations pending

              # Remove completed futures from pending list
              var i = 0
              while i < self.pending_futures.len:
                if self.pending_futures[i].state != FsPending:
                  self.pending_futures.delete(i)
                else:
                  i.inc()

            # Future has completed, handle the result
            case future.state:
              of FsSuccess:
                self.frame.push(future.value)
              of FsFailure:
                # Re-throw the exception
                self.current_exception = future.value
                if self.exception_handlers.len > 0:
                  let handler = self.exception_handlers[^1]
                  self.cu = handler.cu
                  self.pc = handler.catch_pc
                  if self.pc < self.cu.instructions.len:
                    inst = self.cu.instructions[self.pc].addr
                  else:
                    raise new_exception(types.Exception, "Invalid catch PC: " & $self.pc)
                  continue
                else:
                  raise new_exception(types.Exception, self.format_runtime_exception(future.value))
              of FsPending:
                # Should not happen
                not_allowed("Future still pending after polling")
        {.pop.}

      of IkSpawnThread:
        # Spawn a new thread
        {.push checks: off}
        # Threading support - spawn_thread is imported at top level
        let return_value_flag = self.frame.pop()
        let code_val = self.frame.pop()
        let return_value = return_value_flag == TRUE
        let code = cast[ptr Gene](code_val)  # Gene AST
        let result = spawn_thread(code, return_value)
        self.frame.push(result)
        {.pop.}

      of IkTryUnwrap:
        # ? operator: unwrap Ok/Some or return early with Err/None
        {.push checks: off}
        let val = self.frame.pop()

        # Check if it's a Gene value (Ok, Err, Some, None are Gene values)
        if val.kind == VkGene and val.gene != nil:
          let gene = val.gene
          if gene.`type`.kind == VkSymbol:
            let type_name = gene.`type`.str
            case type_name:
              of "Ok", "Some":
                # Unwrap: push the inner value
                if gene.children.len > 0:
                  self.frame.push(gene.children[0])
                else:
                  self.frame.push(NIL)
              of "Err", "None":
                # Early return with this value
                # Same logic as IkReturn but simplified
                if self.frame.caller_frame == nil:
                  self.frame.push(val)
                else:
                  # Profile function exit if needed
                  if self.profiling:
                    self.exit_function()

                  # Restore to caller frame using caller_address
                  self.cu = self.frame.caller_address.cu
                  self.pc = self.frame.caller_address.pc
                  inst = self.cu.instructions[self.pc].addr
                  self.frame.update(self.frame.caller_frame)
                  self.frame.ref_count.dec()
                  self.frame.push(val)  # Push the Err/None as return value
                  continue
              else:
                # Not a Result/Option, just push it back (no-op)
                self.frame.push(val)
        else:
          # Not a Gene, just push it back
          self.frame.push(val)
        {.pop.}

      of IkVmDurationStart:
        # Record start time in microseconds (statement-only)
        self.duration_start_us = epochTime() * 1_000_000

      of IkVmDuration:
        # Return elapsed microseconds since duration_start
        if self.duration_start_us == 0.0:
          not_allowed("duration_start is not set")
        let now_us = epochTime() * 1_000_000
        let elapsed = now_us - self.duration_start_us
        self.frame.push(elapsed.to_value())

      of IkMatchGeneType:
        # Pattern matching: check if value matches Gene type
        # arg0 = type symbol to match (e.g., "Ok", "Err", "Some", "None")
        {.push checks: off.}
        let val = self.frame.pop()
        let expected_type = inst.arg0.str  # Symbol string

        var matched = false
        # Handle None as both symbol and Gene
        if expected_type == "None":
          if val.kind == VkSymbol and val.str == "None":
            matched = true
          elif val.kind == VkGene and val.gene != nil:
            if val.gene.`type`.kind == VkSymbol and val.gene.`type`.str == "None":
              matched = true
        elif val.kind == VkGene and val.gene != nil:
          if val.gene.`type`.kind == VkSymbol and val.gene.`type`.str == expected_type:
            matched = true

        self.frame.push(val)  # Keep the value on stack for later use
        self.frame.push(if matched: TRUE else: FALSE)
        {.pop.}

      of IkGetGeneChild:
        # Get gene.children[arg0]
        {.push checks: off.}
        let val = self.frame.pop()
        let idx = inst.arg0.int64.int

        if val.kind == VkGene and val.gene != nil and idx < val.gene.children.len:
          self.frame.push(val.gene.children[idx])
        else:
          self.frame.push(NIL)
        {.pop.}

      # Superinstructions for performance
      of IkPushCallPop:
        # Combined PUSH; CALL; POP for void function calls
        if inst.arg0.kind != VkNativeFn:
          not_allowed("IkPushCallPop currently supports native functions only")
        discard call_native_fn(inst.arg0.ref.native_fn, self, [])
      
      of IkLoadCallPop:
        # Combined LOADK; CALL1; POP
        # TODO: Implement
        discard
      
      of IkGetLocal:
        # Optimized local variable access
        {.push checks: off.}
        self.frame.push(self.frame.scope.members[inst.arg0.int64.int])
        {.pop.}
      
      of IkSetLocal:
        # Optimized local variable set
        {.push checks: off.}
        self.frame.scope.members[inst.arg0.int64.int] = self.frame.current()
        {.pop.}
      
      of IkAddLocal:
        # Combined local variable add
        {.push checks: off.}
        let val = self.frame.pop()
        let local_idx = inst.arg0.int64.int
        let current = self.frame.scope.members[local_idx]
        # Inline add operation for performance
        let sum_result = case current.kind:
          of VkInt:
            case val.kind:
              of VkInt: (current.int64 + val.int64).to_value()
              of VkFloat: add_mixed(current.int64, val.float)
              else: current  # Fallback
          of VkFloat:
            case val.kind:
              of VkInt: add_mixed(val.int64, current.float)
              of VkFloat: add_float_fast(current.float, val.float)
              else: current  # Fallback
          else: current  # Fallback
        self.frame.scope.members[local_idx] = sum_result
        self.frame.push(sum_result)
        {.pop.}
      
      of IkIncLocal:
        # Increment local variable by 1
        {.push checks: off.}
        let local_idx = inst.arg0.int64.int
        let current = self.frame.scope.members[local_idx]
        if current.kind == VkInt:
          self.frame.scope.members[local_idx] = (current.int64 + 1).to_value()
        self.frame.push(self.frame.scope.members[local_idx])
        {.pop.}
      
      of IkDecLocal:
        # Decrement local variable by 1
        {.push checks: off.}
        let local_idx = inst.arg0.int64.int
        let current = self.frame.scope.members[local_idx]
        if current.kind == VkInt:
          self.frame.scope.members[local_idx] = (current.int64 - 1).to_value()
        self.frame.push(self.frame.scope.members[local_idx])
        {.pop.}
      
      of IkReturnNil:
        # Common pattern: return nil
        if self.frame.caller_frame == nil:
          return NIL
        else:
          let returning_frame = self.frame
          self.pop_frame_exception_handlers(returning_frame)
          if self.current_exception != NIL:
            self.current_exception = NIL
          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()
          self.frame.push(NIL)
          continue
      
      of IkReturnTrue:
        # Common pattern: return true
        if self.frame.caller_frame == nil:
          return TRUE
        else:
          let returning_frame = self.frame
          self.pop_frame_exception_handlers(returning_frame)
          if self.current_exception != NIL:
            self.current_exception = NIL
          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()
          self.frame.push(TRUE)
          continue
      
      of IkReturnFalse:
        # Common pattern: return false
        if self.frame.caller_frame == nil:
          return FALSE
        else:
          let returning_frame = self.frame
          self.pop_frame_exception_handlers(returning_frame)
          if self.current_exception != NIL:
            self.current_exception = NIL
          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()
          self.frame.push(FALSE)
          continue

      # Unified call instructions
      of IkUnifiedCall0:
        {.push checks: off}
        # Zero-argument unified call
        let call_info = self.pop_call_base_info(0)
        when not defined(release):
          if call_info.hasBase and call_info.count != 0:
            raise new_exception(types.Exception, fmt"IkUnifiedCall0 expected 0 args, got {call_info.count}")
        let target = self.frame.pop()

        case target.kind:
        of VkFunction:
          let f = target.ref.fn
          if f.is_generator:
            self.frame.push(new_generator_value(f, @[]))
          else:
            var native_result: Value
            if self.try_native_call(f, @[], native_result):
              self.frame.push(native_result)
            else:
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = FkFunction
              new_frame.target = target
              new_frame.scope = scope
              # OPTIMIZATION: Direct argument processing without Gene objects
              if not f.matcher.is_empty():
                process_args_zero(f.matcher, scope)
              # No need to set new_frame.args for zero-argument functions
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

        of VkNativeFn:
          # Zero arguments - use new signature with nil pointer
          let result = target.ref.native_fn(self, nil, 0, false)
          self.frame.push(result)

        of VkBoundMethod:
          let result = self.call_bound_method(target, @[], @[])
          self.frame.push(result)

        of VkBlock:
          let b = target.ref.block
          if b.body_compiled == nil:
            b.compile()

          var scope: Scope
          if b.matcher.is_empty():
            scope = b.frame.scope
          else:
            scope = new_scope(b.scope_tracker, b.frame.scope)

          var new_frame = new_frame()
          new_frame.kind = FkBlock
          new_frame.target = target
          new_frame.scope = scope
          new_frame.args = new_gene_value()
          if not b.matcher.is_empty():
            process_args_zero(b.matcher, scope)
          new_frame.caller_frame = self.frame
          self.frame.ref_count.inc()
          new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
          new_frame.ns = b.ns

          self.frame = new_frame
          self.cu = b.body_compiled
          self.pc = 0
          inst = self.cu.instructions[self.pc].addr
          continue

        of VkClass:
          # Handle class constructor calls
          let class = target.ref.class
          let instance = new_instance_value(class)

          # Check if class has an init method
          let init_method = class.get_method("init")
          if init_method != nil:
            # Call init method with no arguments
            case init_method.callable.kind:
            of VkFunction:
              let f = init_method.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = init_method.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame
              new_frame.args = new_gene_value()
              new_frame.args.gene.children.add(instance)  # Add self as first argument
              if not f.matcher.is_empty():
                process_args(f.matcher, new_frame.args, scope)
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Call native init method with instance as first argument
              discard call_native_fn(init_method.callable.ref.native_fn, self, [instance])
              self.frame.push(instance)

            else:
              not_allowed("Init method must be a function or native function")
          else:
            # No init method, just return the instance
            self.frame.push(instance)

        of VkInstance, VkCustom:
          # Forward to 'call' method if it exists
          if call_instance_method(self, target, "call", []):
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Instance of " & target.object_class_name & " is not callable (no 'call' method)")
        of VkSelector:
          if call_value_method(self, target, "call", []):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Selector value is not callable (no 'call' method)")

        else:
          not_allowed("IkUnifiedCall0 requires a callable, got " & $target.kind)
        {.pop}

      of IkUnifiedCall1:
        {.push checks: off}
        # Single-argument unified call
        let call_info = self.pop_call_base_info(1)
        when not defined(release):
          if call_info.hasBase and call_info.count != 1:
            raise new_exception(types.Exception, fmt"IkUnifiedCall1 expected 1 arg, got {call_info.count}")
        let arg = self.frame.pop()
        let target = self.frame.pop()

        case target.kind:
        of VkFunction:
          let f = target.ref.fn
          if f.is_generator:
            self.frame.push(new_generator_value(f, @[arg]))
          else:
            var native_result: Value
            if self.try_native_call(f, @[arg], native_result):
              self.frame.push(native_result)
            else:
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = FkFunction
              new_frame.target = target
              new_frame.scope = scope

              # OPTIMIZATION: Direct single-argument processing without Gene objects
              if not f.matcher.is_empty():
                process_args_one(f.matcher, arg, scope)
              # No need to set new_frame.args for single-parameter functions

              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

        of VkNativeFn:
          # Single argument - use new signature with helper
          let result = call_native_fn(target.ref.native_fn, self, [arg])
          self.frame.push(result)

        of VkBoundMethod:
          let result = self.call_bound_method(target, @[arg], @[])
          self.frame.push(result)

        of VkBlock:
          let b = target.ref.block
          if b.body_compiled == nil:
            b.compile()

          var scope: Scope
          if b.matcher.is_empty():
            scope = b.frame.scope
          else:
            scope = new_scope(b.scope_tracker, b.frame.scope)

          var new_frame = new_frame()
          new_frame.kind = FkBlock
          new_frame.target = target
          new_frame.scope = scope
          new_frame.args = new_gene_value()
          new_frame.args.gene.children.add(arg)
          if not b.matcher.is_empty():
            process_args_one(b.matcher, arg, scope)
          new_frame.caller_frame = self.frame
          self.frame.ref_count.inc()
          new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
          new_frame.ns = b.ns

          self.frame = new_frame
          self.cu = b.body_compiled
          self.pc = 0
          inst = self.cu.instructions[self.pc].addr
          continue

        of VkClass:
          # Handle class constructor calls with one argument
          let class = target.ref.class
          let instance = new_instance_value(class)

          # Check if class has an init method
          let init_method = class.get_method("init")
          if init_method != nil:
            # Call init method with one argument
            case init_method.callable.kind:
            of VkFunction:
              let f = init_method.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = init_method.callable
              new_frame.scope = scope
              new_frame.args = new_gene_value()
              new_frame.args.gene.children.add(instance)  # Add self as first argument
              new_frame.args.gene.children.add(arg)       # Add the constructor argument
              if not f.matcher.is_empty():
                process_args(f.matcher, new_frame.args, scope)
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Call native init method with instance and argument
              discard call_native_fn(init_method.callable.ref.native_fn, self, [instance, arg])
              self.frame.push(instance)

            else:
              not_allowed("Init method must be a function or native function")
          else:
            # No init method, just return the instance (ignore the argument)
            self.frame.push(instance)

        of VkInstance, VkCustom:
          # Forward to 'call' method if it exists
          if call_instance_method(self, target, "call", [arg]):
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Instance of " & target.object_class_name & " is not callable (no 'call' method)")
        of VkSelector:
          if call_value_method(self, target, "call", @[arg]):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Selector value is not callable (no 'call' method)")

        else:
          not_allowed("IkUnifiedCall1 requires a callable, got " & $target.kind)
        {.pop}

      of IkCallArgsStart:
        # Mark current stack position (callee already on stack) for dynamic arg counting
        self.frame.push_call_base()

      of IkCallArgSpread:
        # Pop a spreadable value and push its elements onto the stack
        let value = self.frame.pop()
        case value.kind:
          of VkArray:
            for item in array_data(value):
              self.frame.push(item)
          of VkStream:
            for item in value.ref.stream:
              self.frame.push(item)
          of VkNil:
            # Spreading nil is a no-op (treat as empty array/stream)
            discard
          else:
            not_allowed("... can only spread arrays or streams in call context, got " & $value.kind)

      of IkUnifiedCall:
        {.push checks: off}
        # Multi-argument unified call with known arity
        let call_info = self.pop_call_base_info(inst.arg1.int)
        let arg_count = call_info.count
        var args = newSeq[Value](arg_count)
        for i in countdown(arg_count - 1, 0):
          args[i] = self.frame.pop()
        let target = self.frame.pop()

        case target.kind:
        of VkFunction:
          let f = target.ref.fn
          if f.is_generator:
            self.frame.push(new_generator_value(f, args))
          else:
            var native_result: Value
            if self.try_native_call(f, args, native_result):
              self.frame.push(native_result)
            else:
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = FkFunction
              new_frame.target = target
              new_frame.scope = scope

              # OPTIMIZATION: Direct multi-argument processing without Gene objects
              if not f.matcher.is_empty():
                if args.len > 0:
                  process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, scope)
                else:
                  process_args_zero(f.matcher, scope)
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

        of VkNativeFn:
          let result = call_native_fn(target.ref.native_fn, self, args)
          self.frame.push(result)

        of VkBoundMethod:
          let result = self.call_bound_method(target, args, @[])
          self.frame.push(result)

        of VkInstance, VkCustom:
          # Forward to 'call' method if it exists
          if call_instance_method(self, target, "call", args):
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Instance of " & target.object_class_name & " is not callable (no 'call' method)")
        of VkSelector:
          if call_value_method(self, target, "call", args):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Selector value is not callable (no 'call' method)")

        of VkBlock:
          let b = target.ref.block
          if b.body_compiled == nil:
            b.compile()

          var scope: Scope
          if b.matcher.is_empty():
            scope = b.frame.scope
          else:
            scope = new_scope(b.scope_tracker, b.frame.scope)

          var new_frame = new_frame()
          new_frame.kind = FkBlock
          new_frame.target = target
          new_frame.scope = scope
          new_frame.args = new_gene_value()
          for arg in args:
            new_frame.args.gene.children.add(arg)
          if not b.matcher.is_empty():
            process_args_direct(b.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, scope)
          new_frame.caller_frame = self.frame
          self.frame.ref_count.inc()
          new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
          new_frame.ns = b.ns

          self.frame = new_frame
          self.cu = b.body_compiled
          self.pc = 0
          inst = self.cu.instructions[self.pc].addr
          continue

        of VkInterception:
          if args.len == 0:
            not_allowed("Intercepted callable requires self as first argument")
          let instance = args[0]
          let call_args = if args.len > 1: args[1..^1] else: @[]
          let result = self.run_intercepted_method(target.ref.interception, instance, call_args, @[])
          self.frame.push(result)

        else:
          not_allowed("IkUnifiedCall requires a callable, got " & $target.kind)
        {.pop}

      of IkUnifiedCallKw:
        {.push checks: off}
        # Multi-argument unified call with keyword arguments (no spreads)
        let kw_count = inst.arg0.int64.int
        let expected = inst.arg1.int
        let call_info = self.pop_call_base_info(expected)
        let total_items = call_info.count
        let keyword_items = kw_count * 2
        if total_items < keyword_items:
          not_allowed("IkUnifiedCallKw expected at least " & $(keyword_items) & " stack args, got " & $total_items)
        let pos_count = total_items - keyword_items

        var args = newSeq[Value](pos_count)
        for i in countdown(pos_count - 1, 0):
          args[i] = self.frame.pop()

        var kw_pairs = newSeq[(Key, Value)](kw_count)
        for i in countdown(kw_count - 1, 0):
          let value = self.frame.pop()
          let key_val = self.frame.pop()
          kw_pairs[i] = (cast[Key](key_val), value)

        let target = self.frame.pop()

        case target.kind:
        of VkFunction:
          let f = target.ref.fn
          if f.is_generator:
            self.frame.push(new_generator_value(f, args))
          else:
            var native_result: Value
            if self.try_native_call(f, args, native_result):
              self.frame.push(native_result)
            else:
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = FkFunction
              new_frame.target = target
              new_frame.scope = scope

              if not f.matcher.is_empty():
                let args_ptr = if args.len > 0: cast[ptr UncheckedArray[Value]](args[0].addr) else: nil
                if args.len > 0 or kw_pairs.len > 0:
                  process_args_direct_kw(f.matcher, args_ptr, args.len, kw_pairs, scope)
                else:
                  process_args_zero(f.matcher, scope)
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

        of VkNativeFn:
          var native_args = newSeq[Value](args.len + 1)
          let kw_map =
            if kw_pairs.len == 0:
              new_map_value()
            else:
              var m = new_map_value()
              for (k, v) in kw_pairs:
                map_data(m)[k] = v
              m
          native_args[0] = kw_map
          for i, arg in args:
            native_args[i + 1] = arg
          let result = call_native_fn(target.ref.native_fn, self, native_args, kw_pairs.len > 0)
          self.frame.push(result)

        of VkBoundMethod:
          let result = self.call_bound_method(target, args, kw_pairs)
          self.frame.push(result)

        of VkInstance, VkCustom:
          if call_instance_method(self, target, "call", args, kw_pairs):
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Instance of " & target.object_class_name & " is not callable (no 'call' method)")
        of VkSelector:
          if call_value_method(self, target, "call", args, kw_pairs):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Selector value is not callable (no 'call' method)")

        of VkBlock:
          let b = target.ref.block
          if b.body_compiled == nil:
            b.compile()

          var scope: Scope
          if b.matcher.is_empty():
            scope = b.frame.scope
          else:
            scope = new_scope(b.scope_tracker, b.frame.scope)

          var new_frame = new_frame()
          new_frame.kind = FkBlock
          new_frame.target = target
          new_frame.scope = scope
          new_frame.args = new_gene_value()
          for arg in args:
            new_frame.args.gene.children.add(arg)
          if not b.matcher.is_empty():
            let args_ptr = if args.len > 0: cast[ptr UncheckedArray[Value]](args[0].addr) else: nil
            process_args_direct_kw(b.matcher, args_ptr, args.len, kw_pairs, scope)
          new_frame.caller_frame = self.frame
          self.frame.ref_count.inc()
          new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
          new_frame.ns = b.ns

          self.frame = new_frame
          self.cu = b.body_compiled
          self.pc = 0
          inst = self.cu.instructions[self.pc].addr
          continue

        else:
          not_allowed("IkUnifiedCallKw requires a callable, got " & $target.kind)
        {.pop}

      of IkUnifiedCallDynamic:
        {.push checks: off}
        # Dynamic-arity unified call (arg count determined at runtime)
        let call_info = self.pop_call_base_info(-1)
        let arg_count = call_info.count
        var args = newSeq[Value](arg_count)
        for i in countdown(arg_count - 1, 0):
          args[i] = self.frame.pop()
        let target = self.frame.pop()

        case target.kind:
        of VkFunction:
          let f = target.ref.fn
          if f.is_generator:
            self.frame.push(new_generator_value(f, args))
          else:
            var native_result: Value
            if self.try_native_call(f, args, native_result):
              self.frame.push(native_result)
            else:
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = FkFunction
              new_frame.target = target
              new_frame.scope = scope

              # OPTIMIZATION: Direct multi-argument processing without Gene objects
              if not f.matcher.is_empty():
                # Convert seq[Value] to ptr UncheckedArray[Value] for direct processing
                if args.len > 0:
                  process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, scope)
                else:
                  process_args_zero(f.matcher, scope)
              # No need to set new_frame.args for optimized argument processing

              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

        of VkNativeFn:
          # Multi-argument - use new signature with helper
          let result = call_native_fn(target.ref.native_fn, self, args)
          self.frame.push(result)

        of VkBoundMethod:
          let result = self.call_bound_method(target, args, @[])
          self.frame.push(result)

        of VkInstance, VkCustom:
          # Forward to 'call' method if it exists
          if call_instance_method(self, target, "call", args):
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Instance of " & target.object_class_name & " is not callable (no 'call' method)")
        of VkSelector:
          if call_value_method(self, target, "call", args):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
          else:
            not_allowed("Selector value is not callable (no 'call' method)")

        of VkBlock:
          let b = target.ref.block
          if b.body_compiled == nil:
            b.compile()

          var scope: Scope
          if b.matcher.is_empty():
            scope = b.frame.scope
          else:
            scope = new_scope(b.scope_tracker, b.frame.scope)

          var new_frame = new_frame()
          new_frame.kind = FkBlock
          new_frame.target = target
          new_frame.scope = scope
          new_frame.args = new_gene_value()
          for arg in args:
            new_frame.args.gene.children.add(arg)
          if not b.matcher.is_empty():
            process_args_direct(b.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, scope)
          new_frame.caller_frame = self.frame
          self.frame.ref_count.inc()
          new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
          new_frame.ns = b.ns

          self.frame = new_frame
          self.cu = b.body_compiled
          self.pc = 0
          inst = self.cu.instructions[self.pc].addr
          continue

        else:
          not_allowed("IkUnifiedCallDynamic requires a callable, got " & $target.kind)
        {.pop}

      of IkCallSuperMethod, IkCallSuperMethodMacro:
        {.push checks: off}
        let expected = inst.arg1.int
        let call_info = self.pop_call_base_info(expected)
        let arg_count = call_info.count
        var args: seq[Value] = @[]
        if arg_count > 0:
          args = newSeq[Value](arg_count)
          for i in countdown(arg_count - 1, 0):
            args[i] = self.frame.pop()
        let (instance, parent_class) = self.resolve_current_instance_and_parent()
        let saved_frame = self.frame
        if self.call_super_method_resolved(parent_class, instance, inst.arg0.str, args, inst.kind == IkCallSuperMethodMacro, @[]):
          if self.frame == saved_frame:
            self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkCallSuperCtor, IkCallSuperCtorMacro:
        {.push checks: off}
        let expected = inst.arg1.int
        let call_info = self.pop_call_base_info(expected)
        let arg_count = call_info.count
        var args: seq[Value] = @[]
        if arg_count > 0:
          args = newSeq[Value](arg_count)
          for i in countdown(arg_count - 1, 0):
            args[i] = self.frame.pop()
        let (instance, parent_class) = self.resolve_current_instance_and_parent()
        let saved_frame = self.frame
        if self.call_super_constructor(parent_class, instance, args, inst.kind == IkCallSuperCtorMacro):
          if self.frame == saved_frame:
            self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkUnifiedMethodCall0:
        {.push checks: off}
        # Zero-argument unified method call
        let call_info = self.pop_call_base_info(0)
        when not defined(release):
          if call_info.hasBase and call_info.count != 0:
            raise new_exception(types.Exception, fmt"IkUnifiedMethodCall0 expected 0 args, got {call_info.count}")
        let method_name = inst.arg0.str
        let obj = self.frame.pop()
        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name, @[], @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
        if obj.kind notin {VkInstance, VkCustom}:
          if call_value_method(self, obj, method_name, []):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
        
        case obj.kind:
        of VkInstance, VkCustom:
          # OPTIMIZATION: Use inline cache for method lookup
          let class = obj.get_object_class()
          if class.is_nil:
            not_allowed("Object has no class for method call")
          var cache: ptr InlineCache
          if self.pc < self.cu.inline_caches.len:
            cache = self.cu.inline_caches[self.pc].addr
          else:
            while self.cu.inline_caches.len <= self.pc:
              self.cu.inline_caches.add(InlineCache())
            cache = self.cu.inline_caches[self.pc].addr

          var meth: Method
          if cache.class != nil and cache.class == class and cache.class_version == class.version and cache.cached_method != nil:
            # CACHE HIT: Use cached method
            meth = cache.cached_method
          else:
            # CACHE MISS: Look up method and cache it
            meth = class.get_method(method_name)
            if meth != nil:
              cache.class = class
              cache.class_version = class.version
              cache.cached_method = meth

          if meth != nil:
            case meth.callable.kind:
            of VkFunction:
              # OPTIMIZED: Follow IkCallMethod1 pattern for zero-arg method calls
              let f = meth.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              # Use exact same scope optimization as original IkCallMethod1
              var scope: Scope
              if f.matcher.is_empty():
                # FAST PATH: Reuse parent scope directly
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                # SLOW PATH: Create new scope and bind arguments
                scope = new_scope(f.scope_tracker, f.parent_scope)
                if f.matcher.hint_mode == MhSimpleData and f.matcher.children.len == 1:
                  # Manual argument matching: set self in scope without Gene objects
                  if f.scope_tracker.mappings.len > 0 and f.scope_tracker.mappings.hasKey("self".to_key()):
                    let self_idx = f.scope_tracker.mappings["self".to_key()]
                    while scope.members.len <= self_idx:
                      scope.members.add(NIL)
                    scope.members[self_idx] = obj
                else:
                  let args_arr = [obj]
                  process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args_arr[0].addr), 1, false, scope)

              # ULTRA-OPTIMIZED: Minimal frame creation (like original IkCallMethod1)
              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = meth.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns
              # Set frame.args so IkSelf can access self
              let args_gene = new_gene_value()
              args_gene.gene.children.add(obj)
              new_frame.args = args_gene

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Method call with self as first argument
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj])
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, @[], @[])
              self.frame.push(result)
            else:
              not_allowed("Method must be a function or native function")
          else:
            not_allowed("Method " & method_name & " not found on instance")
        of VkString, VkArray, VkMap, VkFuture, VkGenerator:
          # Use template to get class
          let value_class = get_value_class(obj)
          if value_class == nil:
            not_allowed($obj.kind & " class not initialized")

          let method_key = method_name.to_key()
          if value_class.methods.hasKey(method_key):
            let meth = value_class.methods[method_key]
            case meth.callable.kind:
            of VkNativeFn:
              # Method call with self as first argument
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj])
              self.frame.push(result)
            else:
              not_allowed($obj.kind & " method must be a native function")
          else:
            not_allowed("Method " & method_name & " not found on " & $obj.kind)
        else:
          not_allowed("Unified method call not supported for " & $obj.kind)
        {.pop}

      of IkUnifiedMethodCall1:
        {.push checks: off}
        # Single-argument unified method call
        let call_info = self.pop_call_base_info(1)
        when not defined(release):
          if call_info.hasBase and call_info.count != 1:
            raise new_exception(types.Exception, fmt"IkUnifiedMethodCall1 expected 1 arg, got {call_info.count}")
        let method_name = inst.arg0.str
        let arg = self.frame.pop()
        let obj = self.frame.pop()
        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name, [arg], @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        if obj.kind notin {VkInstance, VkCustom}:
          if call_value_method(self, obj, method_name, [arg]):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        case obj.kind:
        of VkInstance, VkCustom:
          # OPTIMIZATION: Use inline cache for method lookup
          let class = obj.get_object_class()
          if class.is_nil:
            not_allowed("Object has no class for method call")
          var cache: ptr InlineCache
          if self.pc < self.cu.inline_caches.len:
            cache = self.cu.inline_caches[self.pc].addr
          else:
            while self.cu.inline_caches.len <= self.pc:
              self.cu.inline_caches.add(InlineCache())
            cache = self.cu.inline_caches[self.pc].addr

          var meth: Method
          if cache.class != nil and cache.class == class and cache.class_version == class.version and cache.cached_method != nil:
            # CACHE HIT: Use cached method
            meth = cache.cached_method
          else:
            # CACHE MISS: Look up method and cache it
            meth = class.get_method(method_name)
            if meth != nil:
              cache.class = class
              cache.class_version = class.version
              cache.cached_method = meth

          if meth != nil:
            case meth.callable.kind:
            of VkFunction:
              # OPTIMIZED: Follow IkCallMethod1 pattern for single-arg method calls
              let f = meth.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              # Use exact same scope optimization as IkUnifiedMethodCall0
              var scope: Scope
              if f.matcher.is_empty():
                # FAST PATH: Reuse parent scope directly
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                # SLOW PATH: Create new scope and bind arguments
                scope = new_scope(f.scope_tracker, f.parent_scope)
                if f.matcher.hint_mode == MhSimpleData and f.matcher.children.len == 2:
                  # Manual argument matching: set self and arg in scope without Gene objects
                  if f.scope_tracker.mappings.hasKey("self".to_key()):
                    let self_idx = f.scope_tracker.mappings["self".to_key()]
                    while scope.members.len <= self_idx:
                      scope.members.add(NIL)
                    scope.members[self_idx] = obj

                  let param = f.matcher.children[1]  # Second param is the actual argument
                  if param.kind == MatchData and f.scope_tracker.mappings.hasKey(param.name_key):
                    let arg_idx = f.scope_tracker.mappings[param.name_key]
                    while scope.members.len <= arg_idx:
                      scope.members.add(NIL)
                    scope.members[arg_idx] = arg
                else:
                  let args_arr = [obj, arg]
                  process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args_arr[0].addr), 2, false, scope)

              # ULTRA-OPTIMIZED: Minimal frame creation (like IkUnifiedMethodCall0)
              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = meth.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns
              # Set frame.args so IkSelf can access self
              let args_gene = new_gene_value()
              args_gene.gene.children.add(obj)
              args_gene.gene.children.add(arg)
              new_frame.args = args_gene

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,  # Special marker for async function
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Method call with self and one argument
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg])
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, @[arg], @[])
              self.frame.push(result)

            else:
              not_allowed("Method must be a function or native function")
          else:
            not_allowed("Method " & method_name & " not found on instance")
        of VkString, VkArray, VkMap, VkFuture, VkGenerator:
          # Use template to get class
          let value_class = get_value_class(obj)
          if value_class == nil:
            not_allowed($obj.kind & " class not initialized")

          let method_key = method_name.to_key()
          if value_class.methods.hasKey(method_key):
            let meth = value_class.methods[method_key]
            case meth.callable.kind:
            of VkNativeFn:
              # Method call with self and one argument
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg])
              self.frame.push(result)
            else:
              not_allowed($obj.kind & " method must be a native function")
          else:
            not_allowed("Method " & method_name & " not found on " & $obj.kind)
        else:
          not_allowed("Unified method call not supported for " & $obj.kind)
        {.pop}

      of IkUnifiedMethodCall2:
        {.push checks: off}
        # Two-argument unified method call
        let call_info = self.pop_call_base_info(2)
        when not defined(release):
          if call_info.hasBase and call_info.count != 2:
            raise new_exception(types.Exception, fmt"IkUnifiedMethodCall2 expected 2 args, got {call_info.count}")
        let method_name = inst.arg0.str
        let arg2 = self.frame.pop()
        let arg1 = self.frame.pop()
        let obj = self.frame.pop()
        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name, [arg1, arg2], @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        if obj.kind notin {VkInstance, VkCustom}:
          if call_value_method(self, obj, method_name, [arg1, arg2]):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        case obj.kind:
        of VkInstance, VkCustom:
          # OPTIMIZATION: Use inline cache for method lookup
          let class = obj.get_object_class()
          if class.is_nil:
            not_allowed("Object has no class for method call")
          var cache: ptr InlineCache
          if self.pc < self.cu.inline_caches.len:
            cache = self.cu.inline_caches[self.pc].addr
          else:
            while self.cu.inline_caches.len <= self.pc:
              self.cu.inline_caches.add(InlineCache())
            cache = self.cu.inline_caches[self.pc].addr

          var meth: Method
          if cache.class != nil and cache.class == class and cache.class_version == class.version and cache.cached_method != nil:
            # CACHE HIT: Use cached method
            meth = cache.cached_method
          else:
            # CACHE MISS: Look up method and cache it
            meth = class.get_method(method_name)
            if meth != nil:
              cache.class = class
              cache.class_version = class.version
              cache.cached_method = meth

          if meth != nil:
            case meth.callable.kind:
            of VkFunction:
              # OPTIMIZED: Follow IkCallMethod pattern for two-arg method calls
              let f = meth.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              # Use exact same scope optimization as IkUnifiedMethodCall0
              var scope: Scope
              if f.matcher.is_empty():
                # FAST PATH: Reuse parent scope directly
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                # SLOW PATH: Create new scope and bind arguments
                scope = new_scope(f.scope_tracker, f.parent_scope)
                if f.matcher.hint_mode == MhSimpleData and f.matcher.children.len == 3:
                  # Manual argument matching: set self and 2 args in scope without Gene objects
                  if f.scope_tracker.mappings.hasKey("self".to_key()):
                    let self_idx = f.scope_tracker.mappings["self".to_key()]
                    while scope.members.len <= self_idx:
                      scope.members.add(NIL)
                    scope.members[self_idx] = obj

                  let param1 = f.matcher.children[1]
                  if param1.kind == MatchData and f.scope_tracker.mappings.hasKey(param1.name_key):
                    let arg1_idx = f.scope_tracker.mappings[param1.name_key]
                    while scope.members.len <= arg1_idx:
                      scope.members.add(NIL)
                    scope.members[arg1_idx] = arg1

                  let param2 = f.matcher.children[2]
                  if param2.kind == MatchData and f.scope_tracker.mappings.hasKey(param2.name_key):
                    let arg2_idx = f.scope_tracker.mappings[param2.name_key]
                    while scope.members.len <= arg2_idx:
                      scope.members.add(NIL)
                    scope.members[arg2_idx] = arg2
                else:
                  let args_arr = [obj, arg1, arg2]
                  process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args_arr[0].addr), 3, false, scope)

              # ULTRA-OPTIMIZED: Minimal frame creation
              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = meth.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns
              # Set frame.args so IkSelf can access self
              let args_gene = new_gene_value()
              args_gene.gene.children.add(obj)
              args_gene.gene.children.add(arg1)
              args_gene.gene.children.add(arg2)
              new_frame.args = args_gene

              # If this is an async function, set up exception handler
              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Method call with self and two arguments
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg1, arg2])
              self.frame.push(result)

            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, @[arg1, arg2], @[])
              self.frame.push(result)

            else:
              not_allowed("Method must be a function or native function")
          else:
            not_allowed("Method " & method_name & " not found on instance")
        of VkString, VkArray, VkMap, VkFuture, VkGenerator:
          # Use template to get class
          let value_class = get_value_class(obj)
          if value_class == nil:
            not_allowed($obj.kind & " class not initialized")

          let method_key = method_name.to_key()
          if value_class.methods.hasKey(method_key):
            let meth = value_class.methods[method_key]
            case meth.callable.kind:
            of VkNativeFn:
              # Method call with self and two arguments
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg1, arg2])
              self.frame.push(result)
            else:
              not_allowed($obj.kind & " method must be a native function")
          else:
            not_allowed("Method " & method_name & " not found on " & $obj.kind)
        else:
          not_allowed("Unified method call not supported for " & $obj.kind)
        {.pop}

      of IkUnifiedMethodCall:
        {.push checks: off}
        # Multi-argument unified method call
        let method_name = inst.arg0.str
        let call_info = self.pop_call_base_info((inst.arg1 - 1).int)
        let arg_count = call_info.count  # Excludes self
        var args = newSeq[Value](arg_count)
        for i in countdown(arg_count - 1, 0):
          args[i] = self.frame.pop()
        let obj = self.frame.pop()
        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name, args, @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        if obj.kind notin {VkInstance, VkCustom}:
          if call_value_method(self, obj, method_name, args):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        case obj.kind:
        of VkInstance, VkCustom:
          let class = obj.get_object_class()
          if class.is_nil:
            not_allowed("Object has no class for method call")
          let meth = class.get_method(method_name)
          if meth != nil:
            case meth.callable.kind:
            of VkFunction:
              let f = meth.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = meth.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame
              new_frame.args = new_gene_value()
              new_frame.args.gene.children.add(obj)  # Add self as first argument
              for arg in args:
                new_frame.args.gene.children.add(arg)
              if not f.matcher.is_empty():
                process_args(f.matcher, new_frame.args, scope)
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Multi-argument method call with self as first argument
              var call_args = @[obj]
              call_args.add(args)
              let result = call_native_fn(meth.callable.ref.native_fn, self, call_args)
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, args, @[])
              self.frame.push(result)

            else:
              not_allowed("Method must be a function or native function")
          else:
            not_allowed("Method " & method_name & " not found on instance")
        of VkString, VkArray, VkMap, VkFuture, VkGenerator:
          # Use template to get class
          let value_class = get_value_class(obj)
          if value_class == nil:
            not_allowed($obj.kind & " class not initialized")

          let method_key = method_name.to_key()
          if value_class.methods.hasKey(method_key):
            let meth = value_class.methods[method_key]
            case meth.callable.kind:
            of VkNativeFn:
              # Multi-argument method call with self as first argument
              var call_args = @[obj]
              call_args.add(args)
              let result = call_native_fn(meth.callable.ref.native_fn, self, call_args)
              self.frame.push(result)
            else:
              not_allowed($obj.kind & " method must be a native function")
          else:
            not_allowed("Method " & method_name & " not found on " & $obj.kind)
        else:
          not_allowed("Unified method call not supported for " & $obj.kind)
        {.pop}

      of IkUnifiedMethodCallKw:
        {.push checks: off}
        # Method call with keyword arguments
        # arg0 = method name (symbol)
        # arg1 = keyword count (int32) in lower 16 bits, total items in upper 16 bits
        let method_name = inst.arg0.str
        let kw_count = (inst.arg1.int64 and 0xFFFF).int
        let expected = ((inst.arg1.int64 shr 16) and 0xFFFF).int
        let call_info = self.pop_call_base_info(expected)
        let total_items = call_info.count
        let keyword_items = kw_count * 2
        if total_items < keyword_items:
          not_allowed("IkUnifiedMethodCallKw expected at least " & $(keyword_items) & " stack args, got " & $total_items)
        let pos_count = total_items - keyword_items

        # Pop positional args
        var args = newSeq[Value](pos_count)
        for i in countdown(pos_count - 1, 0):
          args[i] = self.frame.pop()

        # Pop keyword pairs
        var kw_pairs = newSeq[(Key, Value)](kw_count)
        for i in countdown(kw_count - 1, 0):
          let value = self.frame.pop()
          let key_val = self.frame.pop()
          kw_pairs[i] = (cast[Key](key_val), value)

        # Pop object
        let obj = self.frame.pop()

        if obj.kind == VkSuper:
          # For super calls with keyword args, forward positional args and kw_pairs
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name, args, kw_pairs):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        if obj.kind notin {VkInstance, VkCustom}:
          if call_value_method(self, obj, method_name, args, kw_pairs):
            self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        case obj.kind:
        of VkInstance, VkCustom:
          let class = obj.get_object_class()
          if class.is_nil:
            not_allowed("Object has no class for method call")
          let meth = class.get_method(method_name)
          if meth != nil:
            case meth.callable.kind:
            of VkFunction:
              let f = meth.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()

              var scope: Scope
              if f.matcher.is_empty():
                scope = f.parent_scope
                if scope != nil:
                  scope.ref_count.inc()
              else:
                scope = new_scope(f.scope_tracker, f.parent_scope)

              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = meth.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame

              # Process arguments with keyword support
              if not f.matcher.is_empty():
                # Add self as first positional arg
                var all_args = @[obj]
                all_args.add(args)
                let args_ptr = cast[ptr UncheckedArray[Value]](all_args[0].addr)
                process_args_direct_kw(f.matcher, args_ptr, all_args.len, kw_pairs, scope)

              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              new_frame.ns = f.ns

              if f.async:
                self.exception_handlers.add(ExceptionHandler(
                  catch_pc: CATCH_PC_ASYNC_FUNCTION,
                  finally_pc: -1,
                  frame: self.frame,
                  scope: self.frame.scope,
                  cu: self.cu,
                  saved_value: NIL,
                  has_saved_value: false,
                  in_finally: false
                ))

              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

            of VkNativeFn:
              # Method call with self as first argument plus keyword args
              let has_kw = kw_pairs.len > 0
              let offset = if has_kw: 1 else: 0
              var native_args = newSeq[Value](args.len + 1 + offset)
              if has_kw:
                var kw_map = new_map_value()
                for (k, v) in kw_pairs:
                  map_data(kw_map)[k] = v
                native_args[0] = kw_map
              native_args[offset] = obj
              for i, arg in args:
                native_args[i + offset + 1] = arg
              let result = meth.callable.ref.native_fn(self, cast[ptr UncheckedArray[Value]](native_args[0].addr), native_args.len, has_kw)
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, args, kw_pairs)
              self.frame.push(result)

            else:
              not_allowed("Method must be a function or native function")
          else:
            not_allowed("Method " & method_name & " not found on instance")
        else:
          not_allowed("Unified method call with keywords not supported for " & $obj.kind)
        {.pop}

      of IkDynamicMethodCall:
        # Dynamic method call: method name is evaluated at runtime
        # Stack before: [obj, method_name, arg1, arg2, ...]
        # arg1 contains the argument count (excluding obj and method_name)
        let arg_count = inst.arg1.int
        
        # Pop arguments in reverse order
        var args = newSeq[Value](arg_count)
        for i in countdown(arg_count - 1, 0):
          args[i] = self.frame.pop()
        
        # Pop method name (evaluated expression result)
        let method_name_val = self.frame.pop()
        let method_name = case method_name_val.kind
          of VkSymbol: method_name_val.str
          of VkString: method_name_val.str
          else: $method_name_val  # Try to convert to string
        
        # Pop object
        let obj = self.frame.pop()
        
        case obj.kind:
        of VkInstance, VkCustom:
          let class = obj.get_object_class()
          if class.is_nil:
            not_allowed("Object has no class for dynamic method call")
          
          let meth = class.get_method(method_name)
          if meth != nil:
            case meth.callable.kind:
            of VkFunction:
              let f = meth.callable.ref.fn
              if f.body_compiled == nil:
                f.compile()
              
              var scope = new_scope(f.scope_tracker, f.parent_scope)
              
              # Set self in scope
              if f.scope_tracker.mappings.hasKey("self".to_key()):
                let self_idx = f.scope_tracker.mappings["self".to_key()]
                while scope.members.len <= self_idx:
                  scope.members.add(NIL)
                scope.members[self_idx] = obj
              
              # Set arguments in scope
              for i, arg in args:
                if f.matcher.children.len > i + 1:  # +1 for self
                  let param = f.matcher.children[i + 1]
                  if param.kind == MatchData and f.scope_tracker.mappings.hasKey(param.name_key):
                    let arg_idx = f.scope_tracker.mappings[param.name_key]
                    while scope.members.len <= arg_idx:
                      scope.members.add(NIL)
                    scope.members[arg_idx] = arg
              
              var new_frame = new_frame()
              new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
              new_frame.target = meth.callable
              new_frame.scope = scope
              if f.is_macro_like:
                new_frame.caller_context = self.frame
              new_frame.caller_frame = self.frame
              self.frame.ref_count.inc()
              new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
              # Use function's namespace if available, otherwise fall back to current frame's ns or global
              new_frame.ns = if f.ns != nil: f.ns 
                             elif self.frame != nil and self.frame.ns != nil: self.frame.ns
                             else: App.app.global_ns.ref.ns
              
              let args_gene = new_gene_value()
              args_gene.gene.children.add(obj)
              for arg in args:
                args_gene.gene.children.add(arg)
              new_frame.args = args_gene
              
              self.frame = new_frame
              self.cu = f.body_compiled
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue
              
            of VkNativeFn:
              var native_args = newSeq[Value](args.len + 1)
              native_args[0] = obj
              for i, arg in args:
                native_args[i + 1] = arg
              let result = meth.callable.ref.native_fn(self, cast[ptr UncheckedArray[Value]](native_args[0].addr), native_args.len, false)
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, args, @[])
              self.frame.push(result)
            else:
              not_allowed("Method must be a function or native function")
          else:
            not_allowed("Method " & method_name & " not found on instance")
        else:
          not_allowed("Dynamic method call not supported for " & $obj.kind)

      else:
        not_allowed("Unsupported instruction: " & $inst.kind)

    except CatchableError as ex:
      # Route Nim exceptions through Gene's exception handling so try/catch works.
      # Wrap Nim exception into a Gene exception instance with structured data
      # Inline current_trace logic since runtime_helpers is included later
      var trace: SourceTrace = nil
      if not self.cu.is_nil:
        if self.pc >= 0 and self.pc < self.cu.instruction_traces.len:
          trace = self.cu.instruction_traces[self.pc]
          if trace.is_nil and not self.cu.trace_root.is_nil:
            trace = self.cu.trace_root
        elif not self.cu.trace_root.is_nil:
          trace = self.cu.trace_root
      let location = trace_location(trace)
      let ex_val = wrap_nim_exception(ex, location)
      if self.dispatch_exception(ex_val, inst):
        continue
      else:
        raise

    # Record instruction timing
    when not defined(release):
      if self.instruction_profiling:
        let elapsed = cpuTime() - inst_start_time
        let kind = inst_kind_for_profiling  # Use the saved kind, not current inst.kind
        
        # Update or initialize profile for this instruction
        if self.instruction_profile[kind].count == 0:
          self.instruction_profile[kind] = InstructionProfile(
            count: 1,
            total_time: elapsed,
            min_time: elapsed,
            max_time: elapsed
          )
        else:
          self.instruction_profile[kind].count.inc()
          self.instruction_profile[kind].total_time += elapsed
          if elapsed < self.instruction_profile[kind].min_time:
            self.instruction_profile[kind].min_time = elapsed
          if elapsed > self.instruction_profile[kind].max_time:
            self.instruction_profile[kind].max_time = elapsed
    
    {.push checks: off}
    self.pc.inc()
    inst = cast[ptr Instruction](cast[int64](inst) + INST_SIZE)
    {.pop}
  {.pop.}  # End of hot VM execution loop pragma push

# Continue execution from the current PC
# This allows re-entrant execution for coroutines/async contexts
proc exec_continue*(self: ptr VirtualMachine): Value =
  # Call the main exec loop which now uses self.pc
  return self.exec()

# Execute a Gene function with given arguments and return the result
# This preserves the VM state and can be called from async contexts  
proc exec_function*(self: ptr VirtualMachine, fn: Value, args: seq[Value]): Value {.exportc.} =
  if fn.kind != VkFunction:
    return NIL
  
  let f = fn.ref.fn

  var native_result: Value
  if self.try_native_call(f, args, native_result):
    return native_result
  
  # Compile if needed
  if f.body_compiled == nil:
    f.compile()
  
  # Save current VM state
  let saved_cu = self.cu
  let saved_pc = self.pc
  let saved_frame = self.frame
  
  # Create a new scope for the function
  var scope: Scope
  if f.matcher.is_empty():
    scope = f.parent_scope
    # Increment ref_count since the frame will own this reference
    if scope != nil:
      scope.ref_count.inc()
  else:
    scope = new_scope(f.scope_tracker, f.parent_scope)
  
  # Create a new frame for the function
  let new_frame = new_frame()
  new_frame.kind = FkFunction
  new_frame.target = fn
  new_frame.scope = scope
  new_frame.ns = f.ns
  # Increment ref_count when storing caller_frame
  if saved_frame != nil:
    saved_frame.ref_count.inc()
  new_frame.caller_frame = saved_frame  # Set the caller frame so return works
  new_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)
  # Mark this frame as coming from exec_function
  new_frame.from_exec_function = true
  
  # OPTIMIZATION: Direct argument processing for exec_function
  if not f.matcher.is_empty():
    if args.len == 0:
      process_args_zero(f.matcher, scope)
    elif args.len == 1:
      process_args_one(f.matcher, args[0], scope)
    else:
      process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, scope)

  # Set frame.args so IkSelf can access arguments (especially self in methods)
  let args_gene = new_gene_value()
  for arg in args:
    args_gene.gene.children.add(arg)
  new_frame.args = args_gene
  
  # Set up VM for function execution
  self.frame = new_frame
  self.cu = f.body_compiled
  self.pc = 0
  
  # Execute the function
  # exec_continue will run until the function returns or completes
  # The return instruction or IkEnd will detect from_exec_function and stop exec
  let result = self.exec_continue()
  
  # The VM state should already be restored by return or IkEnd
  return result

proc exec_method_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value],
                      caller_context: Frame): Value =
  ## Execute a Gene method with given instance (self) and arguments.
  ## This properly sets up a method frame with self bound in scope.
  if fn.kind != VkFunction:
    return NIL
  
  let f = fn.ref.fn
  
  # Compile if needed
  if f.body_compiled == nil:
    f.compile()
  
  # Save VM state
  let saved_cu = self.cu
  let saved_pc = self.pc
  let saved_frame = self.frame
  
  # Create a new scope for the method
  var scope: Scope
  if f.matcher.is_empty():
    scope = f.parent_scope
    if scope != nil:
      scope.ref_count.inc()
  else:
    scope = new_scope(f.scope_tracker, f.parent_scope)
    # Explicitly set self in scope (critical for property access like /mappings, m/action)
    if f.scope_tracker.mappings.hasKey("self".to_key()):
      let self_idx = f.scope_tracker.mappings["self".to_key()]
      while scope.members.len <= self_idx:
        scope.members.add(NIL)
      scope.members[self_idx] = instance
  
  # Create a new frame for the method
  let new_frame = new_frame()
  new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
  new_frame.target = fn
  new_frame.scope = scope
  new_frame.ns = f.ns
  if f.is_macro_like:
    let ctx = if caller_context != nil: caller_context else: saved_frame
    if ctx != nil:
      new_frame.caller_context = ctx
  if saved_frame != nil:
    saved_frame.ref_count.inc()
  new_frame.caller_frame = saved_frame
  new_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)
  new_frame.from_exec_function = true
  
  # Process additional arguments (excluding self)
  if not f.matcher.is_empty() and args.len > 0:
    # The matcher expects [self, arg1, arg2, ...], self is already set above
    # Process remaining arguments starting from index 1 of matcher
    for i, arg in args:
      if f.matcher.children.len > i + 1:  # +1 because index 0 is self
        let param = f.matcher.children[i + 1]
        if param.kind == MatchData and f.scope_tracker.mappings.hasKey(param.name_key):
          let arg_idx = f.scope_tracker.mappings[param.name_key]
          while scope.members.len <= arg_idx:
            scope.members.add(NIL)
          scope.members[arg_idx] = arg
  
  # Set frame.args so IkSelf can access arguments (especially self in methods)
  let args_gene = new_gene_value()
  args_gene.gene.children.add(instance)
  for arg in args:
    args_gene.gene.children.add(arg)
  new_frame.args = args_gene
  
  # Set up VM for method execution
  self.frame = new_frame
  self.cu = f.body_compiled
  self.pc = 0
  
  # Execute the method
  let result = self.exec_continue()
  
  return result

proc exec_method*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value]): Value {.exportc.} =
  return self.exec_method_impl(fn, instance, args, self.frame)

proc exec_method_kw_impl(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value],
                         kw_pairs: seq[(Key, Value)], caller_context: Frame): Value =
  ## Execute a Gene method with keyword arguments.
  if fn.kind != VkFunction:
    return NIL

  let f = fn.ref.fn
  if f.body_compiled == nil:
    f.compile()

  let saved_cu = self.cu
  let saved_pc = self.pc
  let saved_frame = self.frame

  var scope: Scope
  if f.matcher.is_empty():
    scope = f.parent_scope
    if scope != nil:
      scope.ref_count.inc()
  else:
    scope = new_scope(f.scope_tracker, f.parent_scope)

  var all_args = newSeq[Value](args.len + 1)
  all_args[0] = instance
  for i, arg in args:
    all_args[i + 1] = arg

  if not f.matcher.is_empty():
    let args_ptr = cast[ptr UncheckedArray[Value]](all_args[0].addr)
    process_args_direct_kw(f.matcher, args_ptr, all_args.len, kw_pairs, scope)

  let new_frame = new_frame()
  new_frame.kind = if f.is_macro_like: FkMacroMethod else: FkMethod
  new_frame.target = fn
  new_frame.scope = scope
  new_frame.ns = f.ns
  if f.is_macro_like:
    let ctx = if caller_context != nil: caller_context else: saved_frame
    if ctx != nil:
      new_frame.caller_context = ctx
  if saved_frame != nil:
    saved_frame.ref_count.inc()
  new_frame.caller_frame = saved_frame
  new_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)
  new_frame.from_exec_function = true

  let args_gene = new_gene_value()
  args_gene.gene.children.add(instance)
  for arg in args:
    args_gene.gene.children.add(arg)
  new_frame.args = args_gene

  self.frame = new_frame
  self.cu = f.body_compiled
  self.pc = 0

  let result = self.exec_continue()
  return result

proc exec_method_kw*(self: ptr VirtualMachine, fn: Value, instance: Value, args: seq[Value],
                     kw_pairs: seq[(Key, Value)]): Value {.exportc.} =
  return self.exec_method_kw_impl(fn, instance, args, kw_pairs, self.frame)

proc exec_callable*(self: ptr VirtualMachine, callable: Value, args: seq[Value]): Value =
  ## Execute a callable from native code while preserving VM state.
  ## This is safe to call from native functions/methods that need to invoke Gene callables.
  case callable.kind:
  of VkFunction:
    return self.exec_function(callable, args)
  of VkNativeFn:
    return call_native_fn(callable.ref.native_fn, self, args)
  of VkNativeMethod:
    return call_native_fn(callable.ref.native_method, self, args)
  of VkBoundMethod:
    let bm = callable.ref.bound_method
    return self.exec_callable(bm.`method`.callable, @[bm.self] & args)
  of VkBlock:
    let blk = callable.ref.block
    if blk.body_compiled == nil:
      blk.compile()

    let saved_cu = self.cu
    let saved_pc = self.pc
    let saved_frame = self.frame

    var scope: Scope
    if blk.matcher.is_empty():
      scope = blk.frame.scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(blk.scope_tracker, blk.frame.scope)

    let new_frame = new_frame()
    new_frame.kind = FkBlock
    new_frame.target = callable
    new_frame.scope = scope
    new_frame.ns = blk.ns
    if saved_frame != nil:
      saved_frame.ref_count.inc()
    new_frame.caller_frame = saved_frame
    new_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)
    new_frame.from_exec_function = true

    var args_gene = new_gene_value()
    for arg in args:
      args_gene.gene.children.add(arg)
    new_frame.args = args_gene

    if not blk.matcher.is_empty():
      process_args(blk.matcher, args_gene, new_frame.scope)

    self.frame = new_frame
    self.cu = blk.body_compiled
    self.pc = 0
    return self.exec_continue()
  else:
    not_allowed("Value is not callable: " & $callable.kind)

proc native_trampoline*(
    ctx: ptr NativeContext,
    descriptor_idx: int64,
    args: ptr UncheckedArray[int64],
    argc: int64
): int64 {.cdecl, exportc.} =
  let idx = int(descriptor_idx)
  assert idx >= 0, "negative descriptor index"
  assert idx < int(ctx.descriptor_count), "descriptor index out of range"
  let desc = ctx.descriptors[idx]
  let n = int(argc)
  assert n == desc.argTypes.len, "argc/descriptor mismatch"

  const MAX_NATIVE_ARGS = 8
  assert n <= MAX_NATIVE_ARGS
  var scratch: array[MAX_NATIVE_ARGS, Value]
  for i in 0..<n:
    case desc.argTypes[i]
    of CatInt64:
      scratch[i] = args[i].to_value()
    of CatFloat64:
      scratch[i] = cast[float64](args[i]).to_value()

  var boxed: seq[Value]
  if n == 0:
    boxed = @[]
  else:
    boxed = @scratch[0..<n]

  let result_val = case desc.callable.kind
    of VkFunction:
      ctx.vm.exec_function(desc.callable, boxed)
    of VkNativeFn:
      call_native_fn(desc.callable.ref.native_fn, ctx.vm, boxed)
    of VkBoundMethod:
      let bm = desc.callable.ref.bound_method
      ctx.vm.exec_method(bm.method.callable, bm.self, boxed)
    else:
      ctx.vm.exec_callable(desc.callable, boxed)

  case desc.returnType
  of CrtInt64:
    return result_val.to_int()
  of CrtFloat64:
    return cast[int64](result_val.to_float())
  of CrtValue:
    return cast[int64](result_val)

proc run_module_init*(self: ptr VirtualMachine, module_ns: Namespace): tuple[ran: bool, value: Value] =
  if module_ns == nil:
    return (false, NIL)
  let ran_key = "__init_ran__".to_key()
  if module_ns.members.getOrDefault(ran_key, FALSE) == TRUE:
    return (false, NIL)
  let init_key = "__init__".to_key()
  if not module_ns.members.hasKey(init_key):
    return (false, NIL)
  let init_val = module_ns.members[init_key]
  if init_val == NIL:
    return (false, NIL)
  module_ns.members[ran_key] = TRUE

  let saved_frame = self.frame
  var frame_changed = false
  if saved_frame == nil or saved_frame.ns != module_ns:
    self.frame = new_frame(module_ns)
    frame_changed = true

  var result: Value = NIL
  let module_scope =
    if saved_frame != nil and saved_frame.ns == module_ns: saved_frame.scope else: nil

  if init_val.kind == VkFunction and module_scope != nil:
    let f = init_val.ref.fn
    if f.body_compiled == nil:
      f.compile()

    # Save current VM state
    let saved_cu = self.cu
    let saved_pc = self.pc
    let saved_frame2 = self.frame

    # Reuse module scope for init so module vars live at module scope
    module_scope.ref_count.inc()

    let args = @[module_ns.to_value()]
    if not f.matcher.is_empty():
      if args.len == 0:
        process_args_zero(f.matcher, module_scope)
      elif args.len == 1:
        process_args_one(f.matcher, args[0], module_scope)
      else:
        process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, module_scope)

    let new_frame = new_frame()
    new_frame.kind = FkFunction
    new_frame.target = init_val
    new_frame.scope = module_scope
    new_frame.ns = f.ns
    if saved_frame2 != nil:
      saved_frame2.ref_count.inc()
    new_frame.caller_frame = saved_frame2
    new_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)
    new_frame.from_exec_function = true

    let args_gene = new_gene_value()
    args_gene.gene.children.add(args[0])
    new_frame.args = args_gene

    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    result = self.exec_continue()
  else:
    result = self.exec_callable(init_val, @[module_ns.to_value()])
  if frame_changed:
    self.frame = saved_frame
  return (true, result)

proc maybe_run_module_init*(self: ptr VirtualMachine): tuple[ran: bool, value: Value] =
  if self.frame == nil or self.frame.ns == nil:
    return (false, NIL)
  let ns = self.frame.ns
  let main_key = "__is_main__".to_key()
  if ns.members.getOrDefault(main_key, FALSE) != TRUE:
    return (false, NIL)
  let init_result = self.run_module_init(ns)
  if init_result.ran:
    self.drain_pending_futures()
  return init_result

proc exec*(self: ptr VirtualMachine, code: string, module_name: string): Value =
  let compiled = parse_and_compile(code, module_name, module_mode = true, run_init = false)

  let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
  ns["__module_name__".to_key()] = module_name.to_value()
  ns["__is_main__".to_key()] = TRUE
  
  # Add gene namespace to module namespace
  ns["gene".to_key()] = App.app.gene_ns
  ns["genex".to_key()] = App.app.genex_ns
  App.app.gene_ns.ref.ns["main_module".to_key()] = module_name.to_value()
  
  # Add eval function to the module namespace
  # Add eval function to the namespace if it exists in global_ns
  # NOTE: This line causes issues with reference access in some cases, commenting out for now
  # if App.app.global_ns.kind == VkNamespace:
  #   let global_ns = App.app.global_ns.ref.ns
  #   if global_ns.has_key("eval".to_key()):
  #     ns["eval".to_key()] = global_ns["eval".to_key()]
  
  # Initialize frame if it doesn't exist
  if self.frame == nil:
    self.frame = new_frame(ns)
  else:
    self.frame.update(new_frame(ns))
  
  # Self is now passed as argument, not stored in frame
  let args_gene = new_gene(NIL)
  args_gene.children.add(ns.to_value())
  self.frame.args = args_gene.to_gene_value()
  self.cu = compiled

  let result = self.exec()
  let init_result = self.maybe_run_module_init()
  if init_result.ran:
    return init_result.value
  return result

proc exec*(self: ptr VirtualMachine, stream: Stream, module_name: string): Value =
  ## Execute Gene code from a stream (more memory-efficient for large files)
  let compiled = parse_and_compile(stream, module_name, module_mode = true, run_init = false)

  let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
  ns["__module_name__".to_key()] = module_name.to_value()
  ns["__is_main__".to_key()] = TRUE

  # Add gene namespace to module namespace
  ns["gene".to_key()] = App.app.gene_ns
  ns["genex".to_key()] = App.app.genex_ns
  App.app.gene_ns.ref.ns["main_module".to_key()] = module_name.to_value()

  # Initialize frame if it doesn't exist
  if self.frame == nil:
    self.frame = new_frame(ns)
  else:
    self.frame.update(new_frame(ns))

  # Self is now passed as argument, not stored in frame
  let args_gene = new_gene(NIL)
  args_gene.children.add(ns.to_value())
  self.frame.args = args_gene.to_gene_value()
  self.cu = compiled

  let result = self.exec()
  let init_result = self.maybe_run_module_init()
  if init_result.ran:
    return init_result.value
  return result

# Generator execution implementation
proc exec_generator_impl*(self: ptr VirtualMachine, gen: GeneratorObj): Value {.exportc.} =
  # Check for nil generator
  if gen == nil:
    raise new_exception(types.Exception, "exec_generator_impl: generator is nil")
  
  # Check for nil function
  if gen.function == nil:
    raise new_exception(types.Exception, "exec_generator_impl: generator function is nil")
  
  
  # If generator hasn't started, initialize it
  if gen.state == GsPending:
    # Compile the function if needed
    if gen.function.body_compiled == nil:
      gen.function.compile()
    
    # Save the compilation unit
    gen.cu = gen.function.body_compiled
    
    # Create a new frame for the generator
    gen.frame = new_frame()
    gen.frame.kind = FkFunction
    let fn_ref = new_ref(VkFunction)
    fn_ref.fn = gen.function
    gen.frame.target = fn_ref.to_ref_value()
    
    # Create scope for the generator
    var scope: Scope
    if gen.function.matcher.is_empty():
      scope = gen.function.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(gen.function.scope_tracker, gen.function.parent_scope)
    gen.frame.scope = scope
    gen.frame.ns = gen.function.ns
    
    # Process arguments if any
    if gen.stack.len > 0:
      let args_gene = new_gene(NIL)
      for arg in gen.stack:
        args_gene.children.add(arg)
      gen.frame.args = args_gene.to_gene_value()
      
      # Process arguments through matcher if needed
      if not gen.function.matcher.is_empty():
        process_args(gen.function.matcher, args_gene.to_gene_value(), scope)
    
    # Initialize execution state
    gen.pc = 0
    gen.state = GsRunning
  
  # Check if generator is done
  if gen.done:
    return NOT_FOUND
  
  # Save current VM state
  let saved_cu = self.cu
  let saved_pc = self.pc
  let saved_frame = self.frame
  let saved_exception_handlers = self.exception_handlers
  
  # Set up generator execution context
  self.cu = gen.cu  # Use saved compilation unit
  self.pc = gen.pc
  self.frame = gen.frame
  self.exception_handlers = @[]  # Clear exception handlers for generator
  
  # Mark that we're in a generator
  self.frame.is_generator = true
  
  # Store the generator in the VM so IkYield can access it
  self.current_generator = gen
  
  # Execute using exec_continue which doesn't reset PC
  # The exec loop will handle IkYield specially when is_generator is true
  var result = self.exec_continue()
  
  # Check if generator yielded (IkYield will return a value) or completed
  # The IkYield handler already saved the state, we just need to check if done
  # Check if we hit the end of the generator function
  # After IkEnd returns, PC would be at or past the last instruction
  # Also check if the last executed instruction was IkEnd
  var is_complete = false
  
  
  if self.pc >= self.cu.instructions.len:
    is_complete = true
  elif self.pc < self.cu.instructions.len and self.cu.instructions[self.pc].kind == IkEnd:
    # IkEnd just executed (PC points to it after it returns)
    is_complete = true
  
  if is_complete:
    # Generator completed - don't yield the return value
    gen.done = true
    gen.state = GsDone
    result = NOT_FOUND  # Return NOT_FOUND for completed generators
  else:
    # Generator yielded a value via IkYield
    gen.state = GsRunning
  
  # Restore original VM state
  self.cu = saved_cu
  self.pc = saved_pc
  self.frame = saved_frame
  self.exception_handlers = saved_exception_handlers
  self.current_generator = nil
  
  return result

include "./stdlib"
include "./vm/runtime_helpers"

# Temporarily import http and sqlite modules until extension loading is fixed
when not defined(noExtensions):
  import "../genex/http"
  import "../genex/sqlite"
  import "../genex/html"
  import "../genex/logging"
  import "../genex/test"
  import "../genex/ai/bindings"
  when defined(geneLLM):
    import "../genex/llm"

{.pop.}
