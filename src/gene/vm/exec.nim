## The main exec* proc — the instruction dispatch loop.
## Included from vm.nim — shares its scope.

template get_inline_cache(cu: CompilationUnit, pc: int): ptr InlineCache =
  ## Fast inline cache access. Pre-allocated CUs hit the first branch;
  ## dynamically compiled CUs fall back to on-demand growth.
  if pc < cu.inline_caches.len:
    cu.inline_caches[pc].addr
  else:
    while cu.inline_caches.len <= pc:
      cu.inline_caches.add(InlineCache())
    cu.inline_caches[pc].addr

proc resolve_local_lookup_value(self: ptr VirtualMachine, key: Key): Value {.inline.} =
  if self == nil or self.frame == nil or self.frame.scope == nil or self.frame.scope.tracker == nil:
    return VOID

  let found = self.frame.scope.tracker.locate(key)
  if found.local_index < 0:
    return VOID

  var scope = self.frame.scope
  var depth = found.parent_index
  while depth > 0 and scope != nil:
    depth.dec()
    scope = scope.parent

  if scope == nil:
    return VOID
  let index = found.local_index.int
  if index < 0 or index >= scope.members.len:
    return VOID
  scope.members[index]

proc resolve_dynamic_selector_prop(self: ptr VirtualMachine, prop: Value): Value {.inline.} =
  if prop.kind != VkSymbol and prop.kind != VkString:
    return prop
  let resolved = self.resolve_local_lookup_value(prop.str.to_key())
  case resolved.kind
  of VkInt, VkString, VkSymbol:
    resolved
  else:
    prop

proc call_native_with_gene_args(self: ptr VirtualMachine, native_fn: NativeFn, args_gene: Value): Value {.inline.} =
  if args_gene.kind != VkGene:
    return call_native_fn(native_fn, self, [])

  if args_gene.gene.props.len == 0:
    return call_native_fn(native_fn, self, args_gene.gene.children)

  var native_args = newSeq[Value](args_gene.gene.children.len + 1)
  var kw_map = new_map_value()
  for k, v in args_gene.gene.props:
    map_data(kw_map)[k] = v
  native_args[0] = kw_map
  for i, arg in args_gene.gene.children:
    native_args[i + 1] = arg
  call_native_fn(native_fn, self, native_args, true)

proc validate_instance_native_method_arity(meth: Method, positional_count: int, keyword_count = 0) {.inline.} =
  if meth == nil or not meth.native_signature_known:
    return
  let expected = meth.native_param_types.len
  if keyword_count > 0 or positional_count != expected:
    not_allowed(meth.class.name & "." & meth.name & " expects " & $expected &
                " arguments after self, got " & $positional_count)

proc require_dynamic_method_name(value: Value): string {.inline.} =
  case value.kind
  of VkSymbol, VkString:
    value.str
  of VkNil:
    not_allowed("Dynamic method name cannot be nil")
    ""
  of VkVoid:
    not_allowed("Dynamic method name cannot be void")
    ""
  else:
    not_allowed("Dynamic method name must be string or symbol, got " & $value.kind)
    ""

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
        vm_log(LlDebug, VmExecLogger, fmt"{indent}{self.pc:04X} {inst[]}")

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
            vm_log(LlDebug, VmExecLogger, fmt"{indent}     [Noop at PC {self.pc:04X}, label: {inst.label.int:04X}]")
        discard

      of IkData:
        # IkData provides data for the previous instruction
        # It should not be executed directly - the previous instruction should consume it
        when not defined(release):
          if self.trace:
            vm_log(LlDebug, VmExecLogger, fmt"{indent}     [Data at PC {self.pc:04X}, skipping]")
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

            # Validate return type for implicit returns (function reached end).
            self.validate_return_type_constraint(result_val)

            if f.async:
              # Wrap the return value in a future
              let future_val = new_future_value()
              let future_obj = future_val.ref.future
              discard future_obj.complete(result_val)
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
        # Type check: first from instruction arg1, then from scope tracker metadata.
        if inst.arg1 != NO_TYPE_ID and self.type_check and value != NIL and self.cu != nil and self.cu.type_descriptors.len > 0:
          validate_type(value, inst.arg1.TypeId, self.cu.type_descriptors, "variable")
        else:
          self.validate_local_type_constraint(self.frame.scope.tracker, index, value)
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
        self.validate_local_type_constraint(self.frame.scope.tracker, index, value)
        # Ensure the scope has enough space for the index
        while self.frame.scope.members.len <= index:
          self.frame.scope.members.add(NIL)
        self.frame.scope.members[index] = value

        # Variables are now stored in scope, not in namespace self
        # This simplifies the design

        # Also push the value to the stack (like IkVar)
        self.frame.push(value)
        {.pop.}

      of IkVarDestructure:
        let source = self.frame.pop()
        let payload = inst.arg0
        if payload.kind != VkArray:
          not_allowed("IkVarDestructure expects payload [pattern [indices]]")
        let parts = array_data(payload)
        if parts.len != 2:
          not_allowed("IkVarDestructure payload must contain pattern and index array")
        var pattern = parts[0]
        var raw_indices = parts[1]
        if raw_indices.kind != VkArray:
          not_allowed("IkVarDestructure payload indices must be an array")
        var target_indices: seq[int16] = @[]
        for item in array_data(raw_indices):
          if item.kind notin {VkInt, VkFloat}:
            not_allowed("IkVarDestructure index must be numeric")
          target_indices.add(item.int64.int16)
        bind_destructure_pattern(pattern, source, self.frame.scope, target_indices)
        wasMoved(pattern)
        wasMoved(raw_indices)

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
        self.validate_local_type_constraint(self.frame.scope.tracker, index, value)
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
        self.validate_local_type_constraint(scope.tracker, index, value)
        while scope.members.len <= index:
          scope.members.add(NIL)
        {.push checks: off}
        scope.members[index] = value
        {.pop.}

      of IkAssign:
        # Assign to nearest namespace where symbol already exists; otherwise
        # define it in current namespace.
        let value = self.frame.current()
        let name = cast[Key](inst.arg0.raw)

        var target_ns = self.frame.ns
        var cursor = self.frame.ns
        var found = false

        while cursor != nil:
          if cursor.members.has_key(name):
            target_ns = cursor
            found = true
            break
          if cursor.stop_inheritance:
            break
          cursor = cursor.parent

        if not found and self.thread_local_ns != nil:
          cursor = self.thread_local_ns
          while cursor != nil:
            if cursor.members.has_key(name):
              target_ns = cursor
              found = true
              break
            if cursor.stop_inheritance:
              break
            cursor = cursor.parent

        if target_ns == nil:
          if self.thread_local_ns != nil:
            target_ns = self.thread_local_ns
          elif App.app.global_ns != NIL:
            target_ns = App.app.global_ns.ref.ns

        if target_ns == nil:
          not_allowed("Cannot assign symbol without an active namespace")

        target_ns[name] = value

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
            vm_log(LlDebug, VmExecLogger, "IkRepeatInit remaining=" & $remaining)
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
            vm_log(LlDebug, VmExecLogger, "IkRepeatDecCheck remaining=" & $remaining)
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
        # IkTailCall works like IkGeneEnd but optimizes self-recursive tail calls
        # by reusing the current frame. For all other cases, patches the instruction
        # to IkGeneEnd and re-dispatches so the full IkGeneEnd handler runs.
        {.push checks: off}
        let tco_value = self.frame.current()
        if tco_value.kind == VkFrame:
          let tco_frame = tco_value.ref.frame
          if tco_frame.kind in {FkFunction, FkMethod, FkMacroMethod}:
            let f = tco_frame.target.ref.fn
            if f.body_compiled == nil:
              f.compile()

            if is_function_like(self.frame.kind) and
               self.frame.target.kind == VkFunction and
               self.frame.target.ref.fn == f:
              # Same-function tail call — reuse frame
              discard self.frame.pop()
              self.frame.args = tco_frame.args

              if f.matcher.is_empty():
                self.frame.scope = f.parent_scope
                if self.frame.scope != nil:
                  self.frame.scope.ref_count.inc()
              else:
                self.frame.scope = new_scope(f.scope_tracker, f.parent_scope)
                if is_method_frame(self.frame):
                  var method_args = new_gene(NIL)
                  if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 1:
                    for i in 1..<self.frame.args.gene.children.len:
                      method_args.children.add(self.frame.args.gene.children[i])
                  process_args(f.matcher, method_args.to_gene_value(), self.frame.scope)
                else:
                  process_args(f.matcher, self.frame.args, self.frame.scope)

              self.frame.stack_index = 0
              self.pc = 0
              inst = self.cu.instructions[self.pc].addr
              continue

        # Not optimizable — temporarily patch instruction in-place and re-dispatch
        self.cu.instructions[self.pc].kind = IkGeneEnd
        inst = self.cu.instructions[self.pc].addr
        # Note: instruction stays as IkGeneEnd permanently for this call site.
        # This is safe because IkGeneEnd is a strict superset of IkTailCall behavior,
        # and the TCO opportunity is only lost for this specific call site.
        continue
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

            # Inline cache implementation (pre-allocated at compile time)
            let cache = get_inline_cache(self.cu, self.pc)
            if cache.ns != nil and cache.version == cache.ns.version and name in cache.ns.members:
              # Cache hit - use cached value
              self.frame.push(cache.ns.members[name])
            else:
              # Cache miss - do full lookup
              let resolved = resolve_namespace_value(self.frame.ns, name)
              var found = resolved.found
              var value = resolved.value
              var found_ns = resolved.owner
              if not found:
                # Try thread-local namespace first (for $thread, $main_thread, etc.)
                if self.thread_local_ns != nil:
                  let thread_resolved = resolve_namespace_value(self.thread_local_ns, name)
                  found = thread_resolved.found
                  value = thread_resolved.value
                  found_ns = thread_resolved.owner
              if not found:
                let symbol_name = get_symbol(symbol_index(name))
                not_allowed(symbol_name & " is not defined")
              # Update cache
              if found_ns != nil:
                cache.ns = found_ns
                cache.version = found_ns.version
                cache.value = value

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
            let parent_scope_tracker =
              if self.frame.scope != nil: self.frame.scope.tracker else: nil
            let compiled = compile_init(value, parent_scope_tracker = parent_scope_tracker)
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
            let parent_scope_tracker =
              if self.frame.scope != nil: self.frame.scope.tracker else: nil
            let compiled = compile_init(quoted_value, parent_scope_tracker = parent_scope_tracker)
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
            ensure_mutable_map(target, "set item on")
            map_data(target)[name] = value
          of VkGene:
            ensure_mutable_gene(target, "set property on")
            target.gene.props[name] = value
          of VkNamespace:
            target.ref.ns[name] = value
          of VkClass:
            target.ref.class.ns[name] = value
          of VkInstance:
            # Check property type if class has type annotations
            if self.type_check:
              let cls = target.instance_class
              if cls != nil and name in cls.prop_types:
                let expected_type_id = cls.prop_types[name]
                if expected_type_id != NO_TYPE_ID and cls.prop_type_descs.len > 0 and value != NIL:
                  let prop_name = get_symbol((cast[uint64](name) and PAYLOAD_MASK).int)
                  let warning = validate_or_coerce_type(value, expected_type_id, cls.prop_type_descs, "property " & prop_name)
                  emit_type_warning(warning)
            instance_props(target)[name] = value
          of VkAdapter:
            adapter_set_member(target.ref.adapter, name, value)
          of VkAdapterInternal:
            adapter_internal_set_member(target, name, value)
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
        of VkMap, VkNamespace, VkClass, VkInstance, VkAdapter, VkAdapterInternal:
          let key = case prop.kind:
            of VkString, VkSymbol: prop.str.to_key()
            of VkInt: ($prop.int64).to_key()
            else:
              not_allowed("Invalid property type: " & $prop.kind)
              "".to_key()
          case target.kind:
            of VkMap:
              ensure_mutable_map(target, "set item on")
              map_data(target)[key] = value
            of VkNamespace:
              target.ref.ns[key] = value
            of VkClass:
              target.ref.class.ns[key] = value
            of VkInstance:
              instance_props(target)[key] = value
            of VkAdapter:
              adapter_set_member(target.ref.adapter, key, value)
            of VkAdapterInternal:
              adapter_internal_set_member(target, key, value)
            else:
              discard
        of VkGene:
          ensure_mutable_gene(target, if prop.kind == VkInt: "set child on" else: "set property on")
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
          ensure_mutable_array(target, "set item on")
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

        if has_custom_materializer(value):
          value = materialize_custom(value)
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
            else:
              var member = value.ref.ns[name]
              if member == NIL:
                let sym_name = get_symbol(symbol_index(name))
                member = try_member_missing_handlers(self, value.ref.ns, sym_name)
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
          of VkAdapter:
            # Access member through adapter mapping
            let member = adapter_get_member(self, value, name)
            retain(member)
            self.frame.push(member)
          of VkAdapterInternal:
            # Access member from adapter's internal data
            let member = adapter_internal_get_member(value, name)
            retain(member)
            self.frame.push(member)
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
            of "named_captures":
              member = new_map_value(value.ref.regex_match_named_captures)
            of "start":
              member = value.ref.regex_match_start.to_value()
            of "end":
              member = value.ref.regex_match_end.to_value()
            of "pre_match":
              member = value.ref.regex_match_pre.to_value()
            of "post_match":
              member = value.ref.regex_match_post.to_value()
            else:
              member = NIL
            retain(member)
            self.frame.push(member)
          else:
            vm_log(LlWarn, VmExecLogger, "IkGetMember: attempting to access member '" &
                   $name & "' on value of type " & $value.kind)
            not_allowed("Cannot get member '" & $name & "' on value of type: " & $value.kind)

      of IkGetMemberOrNil:
        # Pop property/index, then target
        var prop: Value
        self.frame.pop2(prop)
        var target: Value
        self.frame.pop2(target)

        # Not found returns VOID by default. Use /! (IkAssertValue) to throw.
        if target == VOID:
          self.frame.push(VOID)
        elif target == NIL:
          self.frame.push(NIL)
        else:
          if has_custom_materializer(target):
            target = materialize_custom(target)
          if target == VOID:
            self.frame.push(VOID)
            continue
          if target == NIL:
            self.frame.push(NIL)
            continue
          case target.kind:
            of VkMap:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              var member = map_data(target).getOrDefault(key, VOID)
              if member == VOID and (prop.kind == VkString or prop.kind == VkSymbol):
                let dynamic_prop = self.resolve_dynamic_selector_prop(prop)
                if dynamic_prop != prop:
                  let dynamic_key = case dynamic_prop.kind:
                    of VkString, VkSymbol: dynamic_prop.str.to_key()
                    of VkInt: ($dynamic_prop.int64).to_key()
                    else:
                      "".to_key()
                  member = map_data(target).getOrDefault(dynamic_key, VOID)
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
                let now_us = host_now_us().float64
                self.duration_start_us = now_us
                self.frame.push(now_us.to_value())
              elif key == "duration".to_key() and (target == App.app.gene_ns or target == App.app.global_ns):
                if self.duration_start_us == 0.0:
                  not_allowed("duration_start is not set")
                let now_us = host_now_us().float64
                let elapsed = now_us - self.duration_start_us
                self.frame.push(elapsed.to_value())
              else:
                var member = target.ref.ns[key]
                if member == NIL:
                  let prop_name = case prop.kind:
                    of VkString, VkSymbol: prop.str
                    of VkInt: $prop.int64
                    else: ""
                  if prop_name.len > 0:
                    member = try_member_missing_handlers(self, target.ref.ns, prop_name)
                if member != NIL:
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
              let member = target.ref.class.get_member(key)
              let ns_member = target.ref.class.ns[key]
              let resolved = if member != NIL: member elif ns_member != NIL: ns_member else: VOID
              if resolved != VOID:
                retain(resolved)
                self.frame.push(resolved)
              else:
                self.frame.push(VOID)
            of VkAdapter:
              let member = adapter_member_or_nil(self, target, prop)
              retain(member)
              self.frame.push(member)
            of VkAdapterInternal:
              let member = adapter_internal_member_or_nil(target, prop)
              retain(member)
              self.frame.push(member)
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
              of "named_captures":
                member = new_map_value(target.ref.regex_match_named_captures)
              of "start":
                member = target.ref.regex_match_start.to_value()
              of "end":
                member = target.ref.regex_match_end.to_value()
              of "pre_match":
                member = target.ref.regex_match_pre.to_value()
              of "post_match":
                member = target.ref.regex_match_post.to_value()
              else:
                member = VOID
              retain(member)
              self.frame.push(member)
            of VkArray:
              var index_prop = prop
              if index_prop.kind != VkInt:
                index_prop = self.resolve_dynamic_selector_prop(index_prop)
              if index_prop.kind == VkInt:
                let idx64 = index_prop.int64
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
          if has_custom_materializer(target):
            target = materialize_custom(target)
          if target == VOID or target == NIL:
            retain(default_val)
            self.frame.push(default_val)
            continue
          case target.kind:
            of VkMap:
              let key = case prop.kind:
                of VkString, VkSymbol: prop.str.to_key()
                of VkInt: ($prop.int64).to_key()
                else:
                  not_allowed("Invalid property type: " & $prop.kind)
                  "".to_key()
              var member = map_data(target).getOrDefault(key, VOID)
              if member == VOID and (prop.kind == VkString or prop.kind == VkSymbol):
                let dynamic_prop = self.resolve_dynamic_selector_prop(prop)
                if dynamic_prop != prop:
                  let dynamic_key = case dynamic_prop.kind:
                    of VkString, VkSymbol: dynamic_prop.str.to_key()
                    of VkInt: ($dynamic_prop.int64).to_key()
                    else:
                      "".to_key()
                  member = map_data(target).getOrDefault(dynamic_key, VOID)
              if member == VOID:
                member = default_val
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
              else:
                var member = target.ref.ns[key]
                if member == NIL:
                  let prop_name = case prop.kind:
                    of VkString, VkSymbol: prop.str
                    of VkInt: $prop.int64
                    else: ""
                  if prop_name.len > 0:
                    member = try_member_missing_handlers(self, target.ref.ns, prop_name)
                if member != NIL:
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
              let member = target.ref.class.get_member(key)
              let ns_member = target.ref.class.ns[key]
              let resolved = if member != NIL: member elif ns_member != NIL: ns_member else: VOID
              if resolved != VOID:
                retain(resolved)
                self.frame.push(resolved)
              else:
                retain(default_val)
                self.frame.push(default_val)
            of VkAdapter:
              let member = adapter_member_or_nil(self, target, prop)
              if member == NIL or member == VOID:
                retain(default_val)
                self.frame.push(default_val)
              else:
                retain(member)
                self.frame.push(member)
            of VkAdapterInternal:
              let member = adapter_internal_member_or_nil(target, prop)
              if member == NIL or member == VOID:
                retain(default_val)
                self.frame.push(default_val)
              else:
                retain(member)
                self.frame.push(member)
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
              var index_prop = prop
              if index_prop.kind != VkInt:
                index_prop = self.resolve_dynamic_selector_prop(index_prop)
              if index_prop.kind == VkInt:
                let idx64 = index_prop.int64
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

      of IkAssertValue:
        let value = self.frame.current()
        if value == VOID:
          not_allowed("Selector did not match (VOID)")
        elif value == NIL:
          not_allowed("Selector matched but value is nil")
        elif value == PLACEHOLDER:
          not_allowed("Selector matched but value is a placeholder")

      of IkValidateSelectorSegment:
        let value = self.frame.current()
        case value.kind
        of VkString, VkSymbol, VkInt:
          discard
        of VkNil:
          not_allowed("Dynamic selector segment cannot be nil")
        of VkVoid:
          not_allowed("Dynamic selector segment cannot be void")
        else:
          not_allowed("Dynamic selector segment must resolve to string, symbol, or int, got " & $value.kind)

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
            ensure_mutable_array(target, "set item on")
            array_data(target)[i] = new_value
          of VkGene:
            let children_len = target.gene.children.len.int64
            if i < 0 or i >= children_len:
              not_allowed("Gene child index out of bounds: " & $i & " (len=" & $children_len & ")")
            ensure_mutable_gene(target, "set child on")
            target.gene.children[i] = new_value
          else:
            when not defined(release):
              if self.trace:
                vm_log(LlWarn, VmExecLogger, fmt"IkSetChild unsupported kind: {target.kind}")
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
                vm_log(LlWarn, VmExecLogger, fmt"IkGetChild unsupported kind: {value.kind}")
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
            vm_log(LlDebug, VmExecLogger, fmt"IkGetChildDynamic: collection={collection}, index={index}")
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
            let step = if collection.ref.range_step == NIL: 1'i64 else: collection.ref.range_step.int64
            let value = start + (i * step)
            self.frame.push(value.to_value())
          else:
            when not defined(release):
              if self.trace:
                vm_log(LlWarn, VmExecLogger, fmt"IkGetChildDynamic unsupported kind: {collection.kind}")
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
        # Fast-path: raw uint64 comparison for common boolean/nil values
        # instead of calling the full to_bool converter.
        let jif_val = self.frame.pop()
        if jif_val.raw != TRUE.raw:
          if jif_val.raw == FALSE.raw or jif_val.raw == NIL.raw or jif_val.raw == VOID.raw:
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
          # Always copy string literals on push so each variable binding gets a
          # private ref_count=1 object that is safe to mutate via .append etc.
          # The interned instruction constant is unaffected.
          self.frame.push(new_str_value(inst.arg0.str))
        else:
          self.frame.push(inst.arg0)
      of IkPushNil:
        self.frame.push(NIL)
      of IkPushTypeValue:
        let type_id = inst.arg0.int64.TypeId
        self.frame.push(new_runtime_type_value(type_id, self.current_runtime_type_descs()))
      of IkPop:
        discard self.frame.pop()
      of IkDup:
        let value = self.frame.current()
        when not defined(release):
          if self.trace:
            vm_log(LlDebug, VmExecLogger, fmt"IkDup: duplicating {value}")
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
            vm_log(LlDebug, VmExecLogger, fmt"IkDupSecond: top={top}, second={second}")
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
            vm_log(LlDebug, VmExecLogger, fmt"IkOver: top={top}, second={second}")
        self.frame.push(top)
        self.frame.push(second)
      of IkLen:
        # Get length of collection
        let value = self.frame.pop()
        let length = value.size()
        when not defined(release):
          if self.trace:
            vm_log(LlDebug, VmExecLogger, fmt"IkLen: size({value}) = {length}")
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
        let frozen = inst.arg1 != 0

        # Create array with exact capacity
        let arr = new_array_value(@[], frozen = frozen)
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
        let current = self.frame.current()
        if current.kind == VkMap:
          map_ptr(current).frozen = inst.arg1 != 0

      of IkHashMapStart:
        self.frame.collection_bases.push(self.frame.stack_index)

      of IkHashMapEnd:
        let base = self.frame.collection_bases.pop()
        let count = int(self.frame.stack_index) - int(base)
        if (count mod 2) != 0:
          not_allowed("HashMap literals expect alternating key/value entries")

        let hash_map = new_hash_map_value(inst.arg1 != 0)
        var i = 0
        while i < count:
          let key = self.frame.stack[base + uint16(i)]
          let value = self.frame.stack[base + uint16(i + 1)]
          hash_map_put(self, hash_map, key, value)
          i += 2

        self.frame.stack_index = base
        self.frame.push(hash_map)

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
            if current.ref.native_frame.args.kind != VkGene:
              current.ref.native_frame.args = new_gene_value()
            current.ref.native_frame.args.gene.props[key] = value
          else:
            not_allowed("Cannot set property on value of type: " & $current.kind)
        {.pop.}
      of IkGeneAddChild:
        {.push checks: off}
        var child: Value
        self.frame.pop2(child)
        let v = self.frame.current()
        when DEBUG_VM:
          vm_log(LlDebug, VmExecLogger, "IkGeneAddChild: v.kind = " & $v.kind & ", child = " & $child)
        when not defined(release):
          # Debug: print stack state when error occurs
          if v.kind == VkSymbol:
            vm_log(LlError, VmExecLogger, "IkGeneAddChild with Symbol on stack")
            vm_log(LlError, VmExecLogger, "  child = " & $child)
            vm_log(LlError, VmExecLogger, "  v (stack top) = " & $v)
            vm_log(LlError, VmExecLogger, "  Stack trace:")
            for i in 0..<min(5, self.frame.stack_index.int):
              vm_log(LlError, VmExecLogger, "    [" & $i & "] = " & $self.frame.stack[i])
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
              vm_log(LlDebug, VmExecLogger, fmt"  Frame kind = {frame.kind}")
            case frame.kind:
              of FkFunction, FkMethod, FkMacroMethod:
                let f = frame.target.ref.fn
                when DEBUG_VM:
                  vm_log(LlDebug, VmExecLogger, fmt"  Function name = {f.name}, has compiled body = {f.body_compiled != nil}")
                if f.body_compiled == nil:
                  f.compile()
                  when DEBUG_VM:
                    vm_log(LlDebug, VmExecLogger, "  After compile, scope_tracker.mappings = " & $f.scope_tracker.mappings)

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
                  vm_log(LlDebug, VmExecLogger, "  Matcher empty? " & $f.matcher.is_empty() &
                         ", matcher.children.len = " & $f.matcher.children.len)
                  if not f.matcher.is_empty():
                    vm_log(LlDebug, VmExecLogger, "  frame.args = " & $frame.args)
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
                          vm_log(LlDebug, VmExecLogger, "Two-argument optimization: arg_count = " &
                                 $arg_count & ", param_count = " & $param_count)
                        let param1 = f.matcher.children[0]
                        let param2 = f.matcher.children[1]
                        # Check for simple parameter bindings
                        if param1.kind == MatchData and not param1.is_splat and param1.children.len == 0 and
                           param2.kind == MatchData and not param2.is_splat and param2.children.len == 0:
                          when DEBUG_VM:
                            vm_log(LlDebug, VmExecLogger, "  Both params are simple bindings")
                          # Direct assignment for both parameters
                          var all_mapped = true
                          if f.scope_tracker.mappings.has_key(param1.name_key) and
                             f.scope_tracker.mappings.has_key(param2.name_key):
                            let idx1 = f.scope_tracker.mappings[param1.name_key]
                            let idx2 = f.scope_tracker.mappings[param2.name_key]
                            let max_idx = max(idx1, idx2)
                            when DEBUG_VM:
                              vm_log(LlDebug, VmExecLogger, "  idx1 = " & $idx1 & ", idx2 = " & $idx2)
                            while frame.scope.members.len <= max_idx:
                              frame.scope.members.add(NIL)
                            when DEBUG_VM:
                              vm_log(LlDebug, VmExecLogger, "  Setting args: [0] = " &
                                     $frame.args.gene.children[0] & " [1] = " &
                                     $frame.args.gene.children[1])
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
                self.frame.replace(self.call_native_with_gene_args(f, frame.args))
              of NfMethod:
                # Native method call - invoke the native function with self as first arg
                let f = frame.target.ref.native_fn
                self.frame.replace(self.call_native_with_gene_args(f, frame.args))
              else:
                not_allowed("Unsupported native frame kind: " & $frame.kind)

          else:
            # Check if this is a gene with a generator function as its type
            let value = self.frame.current()
            if value.kind == VkGene and (inst.arg1 and 2'i32) != 0:
              value.gene.frozen = true
            if value.kind == VkGene and (inst.arg1 and 1'i32) != 0:
              discard
            elif value.kind == VkGene and value.gene.type.kind == VkFunction:
              let f = value.gene.type.ref.fn
              if f.is_generator:
                # Create generator instance with the arguments from the gene
                let gen_value = new_generator_value(f, value.gene.children)
                self.frame.replace(gen_value)
              else:
                discard
            elif value.kind == VkGene and value.gene.type.kind == VkNativeFn:
              let f = value.gene.type.ref.native_fn
              self.frame.replace(self.call_native_with_gene_args(f, value))
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
                    vm_log(LlDebug, VmExecLogger, fmt"IkAdd float+int: {first.float} + {second.int64.float64} = {r}")
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

      of IkMod:
        let second = self.frame.pop()
        let first = self.frame.pop()
        case first.kind:
          of VkInt:
            case second.kind:
              of VkInt:
                self.frame.push(mod_int_fast(first.int64, second.int64))
              of VkFloat:
                self.frame.push(mod_float_fast(first.int64.float64, second.float))
              else:
                not_allowed("Cannot modulo " & $first.kind & " by " & $second.kind)
          of VkFloat:
            case second.kind:
              of VkInt:
                self.frame.push(mod_float_fast(first.float, second.int64.float64))
              of VkFloat:
                self.frame.push(mod_float_fast(first.float, second.float))
              else:
                not_allowed("Cannot modulo " & $first.kind & " by " & $second.kind)
          else:
            not_allowed("Cannot modulo values of type: " & $first.kind)

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
          let updated = self.frame.scope.members[index]
          self.validate_local_type_constraint(self.frame.scope.tracker, index, updated)
          self.frame.push(updated)
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
          let updated = self.frame.scope.members[index]
          self.validate_local_type_constraint(self.frame.scope.tracker, index, updated)
          self.frame.push(updated)
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

      of IkVarModValue:
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

        # Modulo variable by literal
        case var_value.kind:
          of VkInt:
            case literal_value.kind:
              of VkInt:
                self.frame.push(mod_int_fast(var_value.int64, literal_value.int64))
              of VkFloat:
                self.frame.push(mod_float_fast(var_value.int64.float64, literal_value.float))
              else:
                not_allowed("Cannot modulo " & $var_value.kind & " by " & $literal_value.kind)
          of VkFloat:
            case literal_value.kind:
              of VkInt:
                self.frame.push(mod_float_fast(var_value.float, literal_value.int64.float64))
              of VkFloat:
                self.frame.push(mod_float_fast(var_value.float, literal_value.float))
              else:
                not_allowed("Cannot modulo " & $var_value.kind & " by " & $literal_value.kind)
          else:
            not_allowed("Cannot modulo variable of type: " & $var_value.kind)
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

      of IkXor:
        let second = self.frame.pop()
        let first = self.frame.pop()
        if first.to_bool xor second.to_bool:
          self.frame.push(TRUE)
        else:
          self.frame.push(FALSE)

      of IkNot:
        let value = self.frame.pop()
        if value.to_bool:
          self.frame.push(FALSE)
        else:
          self.frame.push(TRUE)

      of IkTypeOf:
        let value = self.frame.pop()
        self.frame.push(runtime_type_name(value).to_value())

      of IkIsType:
        # (x is Type) — check if value is an instance of type
        let type_arg = self.frame.pop()
        let value = self.frame.pop()
        let resolved = self.resolve_runtime_type_arg(type_arg)
        if not resolved.found:
          not_allowed("is requires a type value on the right side")
        if resolved.type_id == NO_TYPE_ID:
          self.frame.push(TRUE)
        else:
          self.frame.push(is_compatible(value, resolved.type_id, resolved.type_descs).to_value())

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
        let runtime_type = ensure_class_runtime_type(self, class)
        let method_key = name.str.to_key()
        let method_callable = fn_value
        runtime_type.methods[method_key] = method_callable
        if method_key == "init".to_key() or method_key == "__init__".to_key():
          runtime_type.initializer = method_callable
        let m = Method(
          name: name.str,
          callable: fn_value,
          class: class,
          native_signature_known: false,
          native_param_types: @[],
          native_return_type: NIL,
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
        if fn_value.ref.fn.is_macro_like:
          not_allowed("Macro-like constructors are not supported")

        if class.constructor != NIL:
          not_allowed("Class '" & class.name & "' already has a constructor")

        # Set the constructor
        class.constructor = fn_value
        let runtime_type = ensure_class_runtime_type(self, class)
        runtime_type.constructor = fn_value

        # Set the function's namespace to the class namespace
        fn_value.ref.fn.ns = class.ns

        # Return the function
        self.frame.push(fn_value)

      of IkDefineProp:
        # Define a typed property on a class
        # arg0 = property name key, arg1 = TypeId (or NO_TYPE_ID)
        let name = cast[Key](inst.arg0.raw)
        let type_id = inst.arg1

        # The class is passed as the first argument during class initialization
        let class_value = if self.frame.args.kind == VkGene and self.frame.args.gene.children.len > 0:
          self.frame.args.gene.children[0]
        else:
          not_allowed("Cannot find class for prop definition")
          NIL

        if class_value.kind != VkClass:
          not_allowed("Can only define props on classes, got " & $class_value.kind)

        let cls = class_value.ref.class
        cls.prop_types[name] = type_id
        if type_id != NO_TYPE_ID and cls.prop_type_descs.len == 0:
          # Copy type descriptors from the compilation unit
          cls.prop_type_descs = self.cu.type_descriptors
        self.frame.push(NIL)

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
        let f = if self.cu != nil:
            if self.cu.type_registry == nil:
              self.cu.type_registry = populate_registry(self.cu.type_descriptors, self.cu.module_path)
            to_function(info.input, self.cu.type_descriptors, self.cu.type_aliases,
              self.cu.module_path, self.cu.type_registry,
              info.type_expectation_ids, info.return_type_id)
          else:
            to_function(info.input, type_expectation_ids = info.type_expectation_ids,
              return_type_id = info.return_type_id)

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
        if f.matcher != nil:
          f.matcher.type_check = self.type_check
          if f.body_compiled != nil and f.body_compiled.type_descriptors.len > 0:
            f.matcher.type_descriptors = f.body_compiled.type_descriptors
          elif self.cu != nil and self.cu.type_descriptors.len > 0:
            f.matcher.type_descriptors = self.cu.type_descriptors
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
        if b.matcher != nil:
          b.matcher.type_check = self.type_check
          if self.cu != nil and self.cu.type_descriptors.len > 0:
            b.matcher.type_descriptors = self.cu.type_descriptors
            b.matcher.type_aliases = self.cu.type_aliases

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

          # Validate return type if the function/method has one declared.
          self.validate_return_type_constraint(v)

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
              discard future_obj.complete(v)
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
            return v

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

        # Create the namespace with inheritance:
        # - nested namespace: inherit from its container namespace
        # - top-level declaration: inherit from current frame namespace
        let ns_parent = if parent_ns != nil: parent_ns else: self.frame.ns
        let ns = new_namespace(ns_parent, name.str)
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

        if not handled:
          let loaded_ns = self.ensure_runtime_module_loaded(module_path, module_ns, is_native)
          self.import_items(loaded_ns, imports)

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
        discard ensure_class_runtime_type(self, class)
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
          raise new_exception(types.Exception, "new requires a class, got " & $class_val.kind)

        if inst.arg1 != 0:
          not_allowed("Macro-like constructors are not supported; use 'new'")

        if class.runtime_type != nil:
          let resolved_ctor = resolve_constructor(class.runtime_type)
          if resolved_ctor != NIL:
            class.constructor = resolved_ctor

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
            self.frame.kind = FkMethod
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
        if has_container:
          let container_value = self.frame.pop()
          target_ns = namespace_from_value(container_value)
        let class = new_class(class_name)
        if parent_class.kind == VkClass:
          class.parent = parent_class.ref.class
          # Inherit parent class namespace to access class members (and module via parent)
          class.ns.parent = class.parent.ns
        else:
          not_allowed("Parent must be a class, got " & $parent_class.kind)
        discard ensure_class_runtime_type(self, class)
        let r = new_ref(VkClass)
        r.class = class
        let v = r.to_ref_value()
        if not local_def:
          target_ns.members[class_key] = v
        self.frame.push(v)

      of IkInterface:
        # Define an interface
        exec_interface(self, inst.arg0)

      of IkInterfaceMethod:
        exec_interface_method(self, inst.arg0)

      of IkInterfaceProp:
        exec_interface_prop(self, inst.arg0, inst.arg1 != 0)

      of IkImplement:
        # Register an implementation
        let is_external = (inst.arg1 and 1) != 0
        let has_body = (inst.arg1 and 2) != 0
        exec_implement(self, inst.arg0, is_external, has_body)

      of IkImplementMethod:
        exec_implement_method(self, inst.arg0)

      of IkImplementCtor:
        exec_implement_ctor(self)

      of IkAdapter:
        # Create an adapter wrapper
        exec_adapter(self)

      of IkResolveMethod:
        # Peek at the object without popping it
        let v = self.frame.current()
        let method_name = inst.arg0.str

        if v.kind == VkAdapter:
          let member = adapter_get_member(self, v, method_name.to_key())
          if member == NIL or member == VOID:
            not_allowed("Method '" & method_name & "' not found on adapter")
          self.frame.push(member)
          self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue

        let class = v.get_class()
        var cache: ptr InlineCache
        cache = get_inline_cache(self.cu, self.pc)

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
            vm_log(LlDebug, VmExecLogger, "  TryStart: catch_pc=" & $catch_pc & ", finally_pc=" & $finally_pc)

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
                vm_log(LlDebug, VmExecLogger, "  Finally: saved value " & $handler.saved_value)
          else:
            handler.has_saved_value = false
            self.exception_handlers[^1] = handler
        when not defined(release):
          if self.trace:
            vm_log(LlDebug, VmExecLogger, "  Finally: starting finally block")

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
                vm_log(LlDebug, VmExecLogger, "  FinallyEnd: restored value " & $handler.saved_value)

        # Now we can pop the exception handler
        if self.exception_handlers.len > 0:
          discard self.exception_handlers.pop()

        when not defined(release):
          if self.trace:
            vm_log(LlDebug, VmExecLogger, "  FinallyEnd: current_exception = " & $self.current_exception)

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
          class_val = App.app.hash_set_class
        of VkTime:
          class_val = App.app.time_class
        of VkDate:
          class_val = App.app.date_class
        of VkDateTime:
          class_val = App.app.datetime_class
        of VkClass:
          class_val = App.app.class_class
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
          class_val = App.app.application_class
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
            # For complex expressions, compile and execute in the caller's scope.
            # Pass the caller's scope tracker so the compiler knows about local variables.
            let parent_tracker = if caller_frame.scope != nil: caller_frame.scope.tracker else: nil
            let compiled = compile_init(expr_to_eval, parent_scope_tracker = parent_tracker)

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
            # Set caller_address so IkEnd/IkReturn can restore cu/pc
            eval_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)

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
        discard future_obj.complete(value)

        self.frame.push(future_val)
        {.pop.}

      of IkAsync:
        # Legacy instruction - just wrap value in future
        {.push checks: off}
        let value = self.frame.pop()
        let future_val = new_future_value()
        let future_obj = future_val.ref.future

        if value.kind == VkException:
          discard future_obj.fail(value)
        else:
          discard future_obj.complete(value)

        self.frame.push(future_val)
        {.pop.}

      of IkAwait:
        # Wait for a Future to complete
        {.push checks: off}
        let future_val = self.frame.pop()

        if future_val.kind != VkFuture:
          not_allowed("await expects a Future, got: " & $future_val.kind)

        let future = future_val.ref.future

        var timeout_ms = -1
        if inst.arg1 != 0:
          case inst.arg0.kind:
          of VkInt:
            timeout_ms = max(0, inst.arg0.int64.int)
          of VkFloat:
            timeout_ms = max(0, (inst.arg0.float64 * 1000.0).int)
          else:
            not_allowed("await ^timeout expects int milliseconds or float seconds")

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
          of FsCancelled:
            let cancelled_error =
              if future.value != NIL: future.value
              else: new_async_error("GENE.ASYNC.CANCELLED", "Future cancelled", "await")
            self.current_exception = cancelled_error
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
              raise new_exception(types.Exception, self.format_runtime_exception(cancelled_error))
          of FsPending:
            # Poll event loop until future completes
            let start_time_us = host_now_us()
            while future.state == FsPending:
              self.event_loop_counter = EVENT_LOOP_POLL_INTERVAL
              self.poll_enabled = true
              self.poll_event_loop()

              if future.state != FsPending:
                break

              if timeout_ms >= 0:
                let elapsed_ms = ((host_now_us() - start_time_us) div 1000).int
                if elapsed_ms >= timeout_ms:
                  let timeout_error = new_async_error("GENE.ASYNC.TIMEOUT", "await timed out", "await")
                  if future.fail(timeout_error):
                    self.execute_future_callbacks(future)
                  self.detach_future_tracking(future)
                  break

              sleep(1)

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
              of FsCancelled:
                let cancelled_error =
                  if future.value != NIL: future.value
                  else: new_async_error("GENE.ASYNC.CANCELLED", "Future cancelled", "await")
                self.current_exception = cancelled_error
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
                  raise new_exception(types.Exception, self.format_runtime_exception(cancelled_error))
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
        let result = spawn_thread(code_val, return_value)
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
                  var return_value = val
                  self.validate_return_type_constraint(return_value)
                  # Profile function exit if needed
                  if self.profiling:
                    self.exit_function()

                  # Restore to caller frame using caller_address
                  self.cu = self.frame.caller_address.cu
                  self.pc = self.frame.caller_address.pc
                  inst = self.cu.instructions[self.pc].addr
                  self.frame.update(self.frame.caller_frame)
                  self.frame.ref_count.dec()
                  self.frame.push(return_value)  # Push the Err/None as return value
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
        self.duration_start_us = host_now_us().float64

      of IkVmDuration:
        # Return elapsed microseconds since duration_start
        if self.duration_start_us == 0.0:
          not_allowed("duration_start is not set")
        let now_us = host_now_us().float64
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
        let local_idx = inst.arg0.int64.int
        let value = self.frame.current()
        self.validate_local_type_constraint(self.frame.scope.tracker, local_idx, value)
        self.frame.scope.members[local_idx] = value
        {.pop.}

      of IkAddLocal:
        # Combined local variable add
        {.push checks: off.}
        let val = self.frame.pop()
        let local_idx = inst.arg0.int64.int
        let current = self.frame.scope.members[local_idx]
        # Inline add operation for performance
        var sum_result = case current.kind:
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
        self.validate_local_type_constraint(self.frame.scope.tracker, local_idx, sum_result)
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
        let updated = self.frame.scope.members[local_idx]
        self.validate_local_type_constraint(self.frame.scope.tracker, local_idx, updated)
        self.frame.push(updated)
        {.pop.}

      of IkDecLocal:
        # Decrement local variable by 1
        {.push checks: off.}
        let local_idx = inst.arg0.int64.int
        let current = self.frame.scope.members[local_idx]
        if current.kind == VkInt:
          self.frame.scope.members[local_idx] = (current.int64 - 1).to_value()
        let updated = self.frame.scope.members[local_idx]
        self.validate_local_type_constraint(self.frame.scope.tracker, local_idx, updated)
        self.frame.push(updated)
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
          var result_value = TRUE
          self.validate_return_type_constraint(result_value)
          let returning_frame = self.frame
          self.pop_frame_exception_handlers(returning_frame)
          if self.current_exception != NIL:
            self.current_exception = NIL
          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()
          self.frame.push(result_value)
          continue

      of IkReturnFalse:
        # Common pattern: return false
        if self.frame.caller_frame == nil:
          return FALSE
        else:
          var result_value = FALSE
          self.validate_return_type_constraint(result_value)
          let returning_frame = self.frame
          self.pop_frame_exception_handlers(returning_frame)
          if self.current_exception != NIL:
            self.current_exception = NIL
          self.cu = self.frame.caller_address.cu
          self.pc = self.frame.caller_address.pc
          inst = self.cu.instructions[self.pc].addr
          self.frame.update(self.frame.caller_frame)
          self.frame.ref_count.dec()
          self.frame.push(result_value)
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
            if self.try_native_call0(f, native_result):
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

        of VkInterception:
          let result = self.run_intercepted_method(target.ref.interception, NIL, @[], @[])
          self.frame.push(result)

        of VkInterface:
          # Interface call with 0 args - error, need an object to adapt
          raise new_exception(types.Exception, "Interface call requires an object to adapt")

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
          if class.runtime_type != nil:
            discard resolve_initializer(class.runtime_type)
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
            if self.try_native_call1(f, arg, native_result):
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

        of VkInterception:
          let result = self.run_intercepted_method(target.ref.interception, NIL, @[arg], @[])
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
          if class.runtime_type != nil:
            discard resolve_initializer(class.runtime_type)
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

        of VkInterface:
          # Interface call with 1 arg - create adapter
          self.frame.push(target)
          self.frame.push(arg)
          exec_adapter(self)

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

        of VkInterface:
          if args.len < 1:
            raise new_exception(types.Exception, "Interface call requires at least 1 argument (the object to adapt)")
          let ctor_args = if args.len > 1: args[1..^1] else: @[]
          self.frame.push(target)
          self.frame.push(args[0])
          exec_adapter(self, ctor_args)

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
          let result = self.run_intercepted_method(target.ref.interception, NIL, args, @[])
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

        of VkClass:
          if App != NIL and App.kind == VkApplication and App.app.class_class.kind == VkClass and
             target.ref.class == App.app.class_class.ref.class:
            if args.len > 0:
              not_allowed("Class(...) dynamic construction only supports keyword arguments")

            var class_name = ""
            var parent_class =
              if App.app.object_class.kind == VkClass:
                App.app.object_class.ref.class
              else:
                nil
            var ctor_value = NIL
            var methods_value = NIL
            var missing_value = NIL

            for (k, v) in kw_pairs:
              let key_name = get_symbol(symbol_index(k))
              case key_name
              of "name":
                case v.kind
                of VkString, VkSymbol:
                  class_name = v.str
                of VkQuote:
                  if v.ref.quote.kind in {VkString, VkSymbol}:
                    class_name = v.ref.quote.str
                  else:
                    not_allowed("Class.name must be a string or symbol")
                else:
                  not_allowed("Class.name must be a string or symbol")
              of "parent":
                if v == NIL:
                  parent_class = nil
                elif v.kind == VkClass:
                  parent_class = v.ref.class
                else:
                  not_allowed("Class.parent must be a class")
              of "ctor":
                ctor_value = v
              of "methods":
                methods_value = v
              of "on_method_missing":
                missing_value = v
              else:
                discard

            if class_name.len == 0:
              not_allowed("Class(...) requires ^name")

            let class = new_class(class_name, parent_class)
            class.ns.parent = self.frame.ns
            class.add_standard_instance_methods()
            discard ensure_class_runtime_type(self, class)

            if ctor_value != NIL:
              if ctor_value.kind notin {VkFunction, VkNativeFn}:
                not_allowed("Class.ctor must be a function or native function")
              class.constructor = ctor_value
              if ctor_value.kind == VkFunction:
                if ctor_value.ref.fn.is_macro_like:
                  not_allowed("Macro-like constructors are not supported")
                ctor_value.ref.fn.ns = class.ns

            if methods_value != NIL:
              if methods_value.kind != VkMap:
                not_allowed("Class.methods must be a map")
              for method_key, method_callable in map_data(methods_value):
                if method_callable.kind notin {VkFunction, VkNativeFn}:
                  not_allowed("Class method values must be functions or native functions")
                let method_name = get_symbol(symbol_index(method_key))
                if method_callable.kind == VkFunction:
                  if method_callable.ref.fn.is_macro_like:
                    not_allowed("Macro-like class methods are not supported")
                  method_callable.ref.fn.ns = class.ns
                class.methods[method_key] = Method(
                  class: class,
                  name: method_name,
                  callable: method_callable,
                  is_macro: method_callable.kind == VkFunction and method_callable.ref.fn.is_macro_like,
                  native_signature_known: false,
                  native_param_types: @[],
                  native_return_type: NIL,
                )

            if missing_value != NIL:
              if missing_value.kind notin {VkFunction, VkNativeFn}:
                not_allowed("Class.on_method_missing must be a function or native function")
              if missing_value.kind == VkFunction:
                if missing_value.ref.fn.is_macro_like:
                  not_allowed("Macro-like class methods are not supported")
                missing_value.ref.fn.ns = class.ns
              class.methods["on_method_missing".to_key()] = Method(
                class: class,
                name: "on_method_missing",
                callable: missing_value,
                is_macro: missing_value.kind == VkFunction and missing_value.ref.fn.is_macro_like,
                native_signature_known: false,
                native_param_types: @[],
                native_return_type: NIL,
              )

            class.version.inc()
            let class_ref = new_ref(VkClass)
            class_ref.class = class
            self.frame.push(class_ref.to_ref_value())
          else:
            not_allowed("Keyword class calls are not supported for " & target.ref.class.name)

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

        of VkInterception:
          let result = self.run_intercepted_method(target.ref.interception, NIL, args, kw_pairs)
          self.frame.push(result)

        of VkInterface:
          if args.len < 1:
            raise new_exception(types.Exception, "Interface call requires at least 1 argument (the object to adapt)")
          let ctor_args = if args.len > 1: args[1..^1] else: @[]
          self.frame.push(target)
          self.frame.push(args[0])
          exec_adapter(self, ctor_args, kw_pairs)

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

        of VkInterception:
          let result = self.run_intercepted_method(target.ref.interception, NIL, args, @[])
          self.frame.push(result)

        of VkInterface:
          if args.len < 1:
            raise new_exception(types.Exception, "Interface call requires at least 1 argument (the object to adapt)")
          let ctor_args = if args.len > 1: args[1..^1] else: @[]
          self.frame.push(target)
          self.frame.push(args[0])
          exec_adapter(self, ctor_args)

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
        if inst.kind == IkCallSuperMethodMacro:
          not_allowed("Macro-like super methods are not supported")
        if self.call_super_method_resolved(parent_class, instance, inst.arg0.str, args, @[]):
          if self.frame == saved_frame:
            self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkCallSuperMethodKw:
        {.push checks: off}
        # arg0 = method name, arg1 = (total_items << 16) | kw_count
        let method_name = inst.arg0.str
        let kw_count = (inst.arg1.int64 and 0xFFFF).int
        let expected = ((inst.arg1.int64 shr 16) and 0xFFFF).int
        let call_info = self.pop_call_base_info(expected)
        let total_items = call_info.count
        let keyword_items = kw_count * 2
        if total_items < keyword_items:
          not_allowed("IkCallSuperMethodKw expected at least " & $(keyword_items) & " stack args, got " & $total_items)
        let pos_count = total_items - keyword_items

        var args = newSeq[Value](pos_count)
        for i in countdown(pos_count - 1, 0):
          args[i] = self.frame.pop()

        var kw_pairs = newSeq[(Key, Value)](kw_count)
        for i in countdown(kw_count - 1, 0):
          let value = self.frame.pop()
          let key_val = self.frame.pop()
          kw_pairs[i] = (cast[Key](key_val), value)

        let (instance, parent_class) = self.resolve_current_instance_and_parent()
        let saved_frame = self.frame
        if method_name.ends_with("!"):
          not_allowed("Macro-like super methods are not supported")
        if self.call_super_method_resolved(parent_class, instance, method_name, args, kw_pairs):
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
        if inst.kind == IkCallSuperCtorMacro:
          not_allowed("Macro-like super constructors are not supported")
        if self.call_super_constructor(parent_class, instance, args):
          if self.frame == saved_frame:
            self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue
        {.pop.}

      of IkCallSuperCtorKw:
        {.push checks: off}
        # arg0 = ctor name, arg1 = (total_items << 16) | kw_count
        let ctor_name = inst.arg0.str
        let kw_count = (inst.arg1.int64 and 0xFFFF).int
        let expected = ((inst.arg1.int64 shr 16) and 0xFFFF).int
        let call_info = self.pop_call_base_info(expected)
        let total_items = call_info.count
        let keyword_items = kw_count * 2
        if total_items < keyword_items:
          not_allowed("IkCallSuperCtorKw expected at least " & $(keyword_items) & " stack args, got " & $total_items)
        let pos_count = total_items - keyword_items

        var args = newSeq[Value](pos_count)
        for i in countdown(pos_count - 1, 0):
          args[i] = self.frame.pop()

        var kw_pairs = newSeq[(Key, Value)](kw_count)
        for i in countdown(kw_count - 1, 0):
          let value = self.frame.pop()
          let key_val = self.frame.pop()
          kw_pairs[i] = (cast[Key](key_val), value)

        let (instance, parent_class) = self.resolve_current_instance_and_parent()
        let saved_frame = self.frame
        if ctor_name.ends_with("!"):
          not_allowed("Macro-like super constructors are not supported")
        if self.call_super_constructor(parent_class, instance, args, kw_pairs):
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
        let method_key_0 = cast[Key](inst.arg0)
        template method_name_0(): string = inst.arg0.str  # computed only when used
        let obj = self.frame.pop()
        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name_0(), @[], @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue
        if obj.kind == VkAdapter:
          self.frame.push(dispatch_adapter_method(self, obj, method_name_0(), @[]))
          self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue
        if obj.kind notin {VkInstance, VkCustom}:
          # Fast path: check inline cache for value-type native methods
          # to avoid the seq allocation in call_value_method → invoke_method_value.
          let value_class = get_value_class(obj)
          if value_class != nil:
            var cache: ptr InlineCache
            cache = get_inline_cache(self.cu, self.pc)
            var meth: Method
            if cache.class != nil and cache.class == value_class and cache.class_version == value_class.version and cache.cached_method != nil:
              meth = cache.cached_method
            else:
              meth = value_class.get_method(method_key_0)
              if meth != nil:
                cache.class = value_class
                cache.class_version = value_class.version
                cache.cached_method = meth
            if meth != nil and meth.callable.kind == VkNativeFn:
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj])
              self.frame.push(result)
              self.pc.inc()
              inst = self.cu.instructions[self.pc].addr
              continue

          if call_value_method(self, obj, method_name_0(), []):
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
          cache = get_inline_cache(self.cu, self.pc)

          var meth: Method
          if cache.class != nil and cache.class == class and cache.class_version == class.version and cache.cached_method != nil:
            # CACHE HIT: Use cached method
            meth = cache.cached_method
          else:
            # CACHE MISS: Look up method and cache it
            meth = class.get_method(method_key_0)
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
                if (not f.matcher.has_type_annotations) and
                   f.matcher.hint_mode == MhSimpleData and f.matcher.children.len == 1:
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
              validate_instance_native_method_arity(meth, 0)
              # Method call with self as first argument
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj])
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, @[], @[])
              self.frame.push(result)
            else:
              not_allowed("Method must be a function or native function")
          else:
            if self.call_missing_method(obj, class, method_name_0(), @[], @[]):
              inst = self.cu.instructions[self.pc].addr
              continue
            not_allowed("Method " & method_name_0() & " not found on instance")
        of VkString, VkArray, VkMap, VkRange, VkGene, VkNamespace, VkFuture, VkGenerator, VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
          # Fallback for value types when fast path didn't fire (e.g. method not found)
          let value_class = get_value_class(obj)
          if value_class == nil:
            not_allowed($obj.kind & " class not initialized")

          if value_class.methods.hasKey(method_key_0):
            let meth = value_class.methods[method_key_0]
            case meth.callable.kind:
            of VkNativeFn:
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj])
              self.frame.push(result)
            else:
              not_allowed($obj.kind & " method must be a native function")
          else:
            not_allowed("Method " & method_name_0() & " not found on " & $obj.kind)
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
        let method_key_1 = cast[Key](inst.arg0)
        template method_name_1(): string = inst.arg0.str
        let arg = self.frame.pop()
        let obj = self.frame.pop()
        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name_1(), [arg], @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        if obj.kind == VkAdapter:
          self.frame.push(dispatch_adapter_method(self, obj, method_name_1(), @[arg]))
          self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue

        if obj.kind notin {VkInstance, VkCustom}:
          # Fast path: inline-cached native method dispatch for value types
          let value_class = get_value_class(obj)
          if value_class != nil:
            var cache: ptr InlineCache
            cache = get_inline_cache(self.cu, self.pc)
            var meth: Method
            if cache.class != nil and cache.class == value_class and cache.class_version == value_class.version and cache.cached_method != nil:
              meth = cache.cached_method
            else:
              meth = value_class.get_method(method_key_1)
              if meth != nil:
                cache.class = value_class
                cache.class_version = value_class.version
                cache.cached_method = meth
            if meth != nil and meth.callable.kind == VkNativeFn:
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg])
              self.frame.push(result)
              self.pc.inc()
              inst = self.cu.instructions[self.pc].addr
              continue

          if call_value_method(self, obj, method_name_1(), [arg]):
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
          cache = get_inline_cache(self.cu, self.pc)

          var meth: Method
          if cache.class != nil and cache.class == class and cache.class_version == class.version and cache.cached_method != nil:
            # CACHE HIT: Use cached method
            meth = cache.cached_method
          else:
            # CACHE MISS: Look up method and cache it
            meth = class.get_method(method_key_1)
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
                if (not f.matcher.has_type_annotations) and
                   f.matcher.hint_mode == MhSimpleData and f.matcher.children.len == 2:
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
              validate_instance_native_method_arity(meth, 1)
              # Method call with self and one argument
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg])
              self.frame.push(result)
            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, @[arg], @[])
              self.frame.push(result)

            else:
              not_allowed("Method must be a function or native function")
          else:
            if self.call_missing_method(obj, class, method_name_1(), [arg], @[]):
              inst = self.cu.instructions[self.pc].addr
              continue
            not_allowed("Method " & method_name_1() & " not found on instance")
        of VkString, VkArray, VkMap, VkRange, VkGene, VkNamespace, VkFuture, VkGenerator, VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
          # Fallback for value types when fast path didn't fire (e.g. method not found)
          let value_class = get_value_class(obj)
          if value_class == nil:
            not_allowed($obj.kind & " class not initialized")

          let method_key = method_key_1
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
            not_allowed("Method " & method_name_1() & " not found on " & $obj.kind)
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

        if obj.kind == VkAdapter:
          self.frame.push(dispatch_adapter_method(self, obj, method_name, @[arg1, arg2]))
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
          cache = get_inline_cache(self.cu, self.pc)

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
                if (not f.matcher.has_type_annotations) and
                   f.matcher.hint_mode == MhSimpleData and f.matcher.children.len == 3:
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
              validate_instance_native_method_arity(meth, 2)
              # Method call with self and two arguments
              let result = call_native_fn(meth.callable.ref.native_fn, self, [obj, arg1, arg2])
              self.frame.push(result)

            of VkInterception:
              let result = self.run_intercepted_method(meth.callable.ref.interception, obj, @[arg1, arg2], @[])
              self.frame.push(result)

            else:
              not_allowed("Method must be a function or native function")
          else:
            if self.call_missing_method(obj, class, method_name, [arg1, arg2], @[]):
              inst = self.cu.instructions[self.pc].addr
              continue
            not_allowed("Method " & method_name & " not found on instance")
        of VkString, VkArray, VkMap, VkRange, VkGene, VkNamespace, VkFuture, VkGenerator, VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
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

        if obj.kind == VkAdapter:
          self.frame.push(dispatch_adapter_method(self, obj, method_name, args))
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
              validate_instance_native_method_arity(meth, args.len)
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
            if self.call_missing_method(obj, class, method_name, args, @[]):
              inst = self.cu.instructions[self.pc].addr
              continue
            not_allowed("Method " & method_name & " not found on instance")
        of VkString, VkArray, VkMap, VkRange, VkGene, VkNamespace, VkFuture, VkGenerator, VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
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

        if obj.kind == VkAdapter:
          self.frame.push(dispatch_adapter_method_kw(self, obj, method_name, args, kw_pairs))
          self.pc.inc()
          inst = self.cu.instructions[self.pc].addr
          continue

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
              validate_instance_native_method_arity(meth, args.len, kw_pairs.len)
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
            if self.call_missing_method(obj, class, method_name, args, kw_pairs):
              inst = self.cu.instructions[self.pc].addr
              continue
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
        let method_name = require_dynamic_method_name(method_name_val)

        # Pop object
        let obj = self.frame.pop()

        if obj.kind == VkSuper:
          let saved_frame = self.frame
          if call_super_method(self, obj, method_name, args, @[]):
            if self.frame == saved_frame:
              self.pc.inc()
            inst = self.cu.instructions[self.pc].addr
            continue

        if obj.kind == VkAdapter:
          self.frame.push(dispatch_adapter_method(self, obj, method_name, args))
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
            not_allowed("Object has no class for dynamic method call")

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
                var all_args = newSeq[Value](args.len + 1)
                all_args[0] = obj
                for i, arg in args:
                  all_args[i + 1] = arg
                process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](all_args[0].addr), all_args.len, false, scope)

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
              validate_instance_native_method_arity(meth, args.len)
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
