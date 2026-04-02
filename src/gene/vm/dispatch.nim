## Call dispatch: pop_call_base_info, unified_call_dispatch, value_to_callable,
## call_instance_method, call_super_method_resolved, call_super_method,
## call_value_method, call_interception_original, run_intercepted_method,
## call_bound_method, current_self_value, find_method_class,
## resolve_current_instance_and_parent, call_super_constructor.
## Included from vm.nim — shares its scope.

const MissingMethodMaxDepth = 32

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

proc resolve_template_symbol(self: ptr VirtualMachine, symbol: Value): Value =
  let key = symbol.str.to_key()

  if self.frame.scope != nil and self.frame.scope.tracker != nil:
    let var_index = self.frame.scope.tracker.locate(key)
    if var_index.local_index >= 0:
      var scope = self.frame.scope
      var parent_index = var_index.parent_index

      while parent_index > 0 and scope != nil:
        parent_index.dec()
        scope = scope.parent

      if scope != nil and var_index.local_index < scope.members.len:
        return scope.members[var_index.local_index]

  if self.frame.ns != nil and self.frame.ns.members.hasKey(key):
    return self.frame.ns.members[key]

  if self.thread_local_ns != nil and self.thread_local_ns.members.hasKey(key):
    return self.thread_local_ns.members[key]

  # Preserve prior fallback behavior for unresolved template variables.
  return symbol

proc eval_template_unquote(self: ptr VirtualMachine, expr: Value): Value =
  case expr.kind:
  of VkSymbol:
    return self.resolve_template_symbol(expr)
  of VkInt, VkFloat, VkBool, VkString, VkChar, VkNil, VkVoid:
    return expr
  else:
    let parent_scope_tracker =
      if self.frame.scope != nil: self.frame.scope.tracker else: nil
    let compiled = compile_init(expr, parent_scope_tracker = parent_scope_tracker)
    let saved_cu = self.cu
    let saved_pc = self.pc
    self.cu = compiled
    let result = self.exec()
    self.cu = saved_cu
    self.pc = saved_pc
    return result

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
      let r = self.eval_template_unquote(expr)

      if discard_result:
        # %_ means discard the r
        return NIL
      else:
        return r

    of VkGene:
      # Recursively render gene expressions
      let gene = tpl.gene
      let new_gene = new_gene(self.render_template(gene.type), frozen = gene.frozen)

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
      var new_arr = new_array_value(@[], frozen = array_is_frozen(tpl))
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
      let new_map = new_map_value(map_is_frozen(tpl))
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

  if class.runtime_type != nil:
    discard resolve_method(class.runtime_type, call_method_key)

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

proc call_super_method_resolved(self: ptr VirtualMachine, parent_class: Class, instance: Value, method_name: string, args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
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

  if class != nil and class.runtime_type != nil:
    discard resolve_method(class.runtime_type, method_key)

  case meth.callable.kind:
  of VkFunction:
    let f = meth.callable.ref.fn
    if f.is_macro_like:
      not_allowed("Macro-like class methods are not supported")

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
    new_frame.kind = FkMethod
    new_frame.target = meth.callable
    new_frame.scope = scope
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
  return self.call_super_method_resolved(super_ref.super_class, super_ref.super_instance, method_name, args, kw_pairs)

proc invoke_method_value(self: ptr VirtualMachine, value: Value, meth: Method,
                         args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
  proc validate_native_method_arity(meth: Method, positional_count: int, keyword_count: int) =
    if not meth.native_signature_known:
      return
    let expected = meth.native_param_types.len
    if keyword_count > 0 or positional_count != expected:
      not_allowed(meth.class.name & "." & meth.name & " expects " & $expected &
                  " arguments after self, got " & $positional_count)

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
    validate_native_method_arity(meth, args.len, kw_pairs.len)
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

proc call_missing_method(self: ptr VirtualMachine, value: Value, value_class: Class,
                         missing_name: string, args: openArray[Value],
                         kw_pairs: seq[(Key, Value)] = @[]): bool =
  if value_class == nil or missing_name == "on_method_missing":
    return false
  if self.missing_method_depth >= MissingMethodMaxDepth:
    not_allowed("on_method_missing recursion limit exceeded while resolving '" & missing_name & "'")
  if value_class.runtime_type != nil:
    discard resolve_method(value_class.runtime_type, "on_method_missing".to_key())
  let missing = value_class.get_method("on_method_missing")
  if missing == nil:
    return false

  self.missing_method_depth.inc()
  # For native methods invoke_method_value completes synchronously, so
  # decrement immediately.  For Gene functions a new frame is pushed and the
  # body executes later in the VM loop — don't decrement here so that the
  # recursive call_missing_method sees the accumulated depth.
  if missing.callable.kind == VkNativeFn:
    defer:
      self.missing_method_depth.dec()

  var missing_args = newSeq[Value](args.len + 1)
  missing_args[0] = missing_name.to_symbol_value()
  for i in 0..<args.len:
    missing_args[i + 1] = args[i]
  self.invoke_method_value(value, missing, missing_args, kw_pairs)

proc call_value_method(self: ptr VirtualMachine, value: Value, method_name: string,
                       args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
  ## Helper for calling native/class methods on non-instance values (strings, selectors, etc.)
  let value_class = get_value_class(value)
  if value_class == nil:
    when not defined(release):
      if self.trace:
        vm_log(LlDebug, VmDispatchLogger, "call_value_method: no class for " & $value.kind & " method " & method_name)
    return false

  if value_class.runtime_type != nil:
    discard resolve_method(value_class.runtime_type, method_name.to_key())

  let meth = value_class.get_method(method_name)
  if meth == nil:
    when not defined(release):
      if self.trace:
        vm_log(LlDebug, VmDispatchLogger, "call_value_method: method " & method_name & " missing on " & $value.kind)
    return self.call_missing_method(value, value_class, method_name, args, kw_pairs)
  self.invoke_method_value(value, meth, args, kw_pairs)

proc run_intercepted_method(self: ptr VirtualMachine, interception: Interception, instance: Value,
                            args: seq[Value], kw_pairs: seq[(Key, Value)] = @[]): Value

proc call_interception_original(self: ptr VirtualMachine, original: Value, instance: Value,
                                args: seq[Value], kw_pairs: seq[(Key, Value)]): Value =
  case original.kind
  of VkFunction:
    if instance == NIL:
      if kw_pairs.len > 0:
        not_allowed("Keyword arguments are not supported for intercepted standalone functions")
      return self.exec_function(original, args)
    if kw_pairs.len > 0:
      return self.exec_method_kw(original, instance, args, kw_pairs)
    return self.exec_method(original, instance, args)
  of VkNativeFn:
    let has_kw = kw_pairs.len > 0
    let has_instance = instance != NIL
    let offset = if has_kw: 1 else: 0
    let extra = if has_instance: 1 else: 0
    var call_args = newSeq[Value](args.len + extra + offset)
    if has_kw:
      var kw_map = new_map_value()
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v
      call_args[0] = kw_map
    if has_instance:
      call_args[offset] = instance
      for i, arg in args:
        call_args[i + offset + 1] = arg
    else:
      for i, arg in args:
        call_args[i + offset] = arg
    return call_native_fn(original.ref.native_fn, self, call_args, has_kw)
  of VkInterception:
    return self.run_intercepted_method(original.ref.interception, instance, args, kw_pairs)
  else:
    not_allowed("Intercepted callable must be a function or native function")

proc run_intercepted_method(self: ptr VirtualMachine, interception: Interception, instance: Value,
                            args: seq[Value], kw_pairs: seq[(Key, Value)] = @[]): Value =
  if not interception.active:
    return self.call_interception_original(interception.original, instance, args, kw_pairs)

  let aspect_val = interception.aspect
  if aspect_val.kind != VkAspect:
    not_allowed("Aspect interception requires a VkAspect")
  let aspect = aspect_val.ref.aspect
  let param_name = interception.param_name
  let wrapped_value =
    if instance == NIL:
      interception.original
    else:
      let wrapped_method = Method(
        class: nil,
        name: param_name,
        callable: interception.original,
        is_macro: false,
        native_signature_known: false,
        native_param_types: @[],
        native_return_type: NIL
      )
      let wrapped_ref = new_ref(VkBoundMethod)
      wrapped_ref.bound_method = BoundMethod(
        self: instance,
        `method`: wrapped_method
      )
      wrapped_ref.to_ref_value()
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
      if advice_fn.user_arg_count < 0 or advice_fn.user_arg_count > args.len:
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
    vm_log(LlWarn, VmDispatchLogger, "super resolve failed: instance.kind=" & $instance.kind &
           " args kind=" & $self.frame.args.kind)
    if self.frame.args.kind == VkGene:
      vm_log(LlWarn, VmDispatchLogger, "super resolve failed: args children len=" &
             $self.frame.args.gene.children.len)
    not_allowed("super requires an instance context")

  let current_class = find_method_class(instance, self.frame.target)
  if current_class.is_nil or current_class.parent.is_nil:
    not_allowed("No parent class available for super")

  (instance, current_class.parent)

proc call_super_constructor(self: ptr VirtualMachine, parent_class: Class, instance: Value, args: openArray[Value], kw_pairs: seq[(Key, Value)] = @[]): bool =
  ## Invoke a superclass constructor without allocation.
  if parent_class == nil:
    not_allowed("No parent class available for super")
  if instance.kind notin {VkInstance, VkCustom}:
    not_allowed("super requires an instance context")

  let ctor = parent_class.get_constructor()
  if ctor.is_nil:
    not_allowed("Superclass has no constructor")

  case ctor.kind:
  of VkFunction:
    let f = ctor.ref.fn
    if f.is_macro_like:
      not_allowed("Macro-like constructors are not supported")

    if f.body_compiled == nil:
      f.compile()

    var scope: Scope
    if f.matcher.is_empty():
      scope = f.parent_scope
      if scope != nil:
        scope.ref_count.inc()
    else:
      scope = new_scope(f.scope_tracker, f.parent_scope)
      var user_args = newSeq[Value](args.len)
      for i in 0..<args.len:
        user_args[i] = args[i]
      let args_ptr =
        if user_args.len > 0:
          cast[ptr UncheckedArray[Value]](user_args[0].addr)
        else:
          cast[ptr UncheckedArray[Value]](nil)
      if kw_pairs.len > 0:
        process_args_direct_kw(f.matcher, args_ptr, user_args.len, kw_pairs, scope)
      else:
        process_args_direct(f.matcher, args_ptr, user_args.len, false, scope)
      assign_property_params(f.matcher, scope, instance)

    var new_frame = new_frame()
    new_frame.kind = FkMethod
    new_frame.target = ctor
    new_frame.scope = scope
    new_frame.caller_frame = self.frame
    self.frame.ref_count.inc()
    new_frame.caller_address = Address(cu: self.cu, pc: self.pc + 1)
    new_frame.ns = f.ns
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
    if kw_pairs.len > 0:
      var native_args = newSeq[Value](args.len + 1)
      var kw_map = new_map_value()
      for (k, v) in kw_pairs:
        map_data(kw_map)[k] = v
      native_args[0] = kw_map
      for i in 0..<args.len:
        native_args[i + 1] = args[i]
      let result = call_native_fn(ctor.ref.native_fn, self, native_args, true)
      self.frame.push(result)
      return true

    let result = call_native_fn(ctor.ref.native_fn, self, args)
    self.frame.push(result)
    return true

  else:
    not_allowed("Superclass constructor must be a function or native function")
    return false
