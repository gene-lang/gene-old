## Exception handling: unwind_scopes_to, dispatch_exception, pop_frame_exception_handlers.
## Included from vm.nim — shares its scope.

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
