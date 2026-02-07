## exec_continue, exec_function, exec_method_impl, exec_method, exec_method_kw_impl,
## exec_method_kw, exec_callable, exec_generator_impl.
## Included from vm.nim — shares its scope.

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
    var all_args = newSeq[Value](args.len + 1)
    all_args[0] = instance
    for i, arg in args:
      all_args[i + 1] = arg
    process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](all_args[0].addr), all_args.len, false, scope)

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
