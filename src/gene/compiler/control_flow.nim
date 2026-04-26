## Control flow and variable compilation:
## compile_do, compile_if, compile_case, compile_var, compile_assignment,
## compile_loop, compile_while, compile_repeat, compile_for, compile_enum,
## compile_break, compile_continue, compile_throw, compile_try.
## Included from compiler.nim — shares its scope.

proc compile_do(self: Compiler, gene: ptr Gene) =
  self.compile(gene.children)

proc start_scope(self: Compiler) =
  let scope_tracker = new_scope_tracker(self.scope_tracker)
  self.scope_trackers.add(scope_tracker)
  self.declared_names.add(initTable[Key, bool]())
  # ScopeStart is added when the first variable is declared
proc add_scope_start(self: Compiler) =
  if self.module_init_mode and self.scope_trackers.len == 1:
    return
  if not self.scope_tracker.scope_started:
    if self.skip_root_scope_start and self.scope_trackers.len == 1:
      self.scope_tracker.scope_started = true
      return
    self.emit(Instruction(kind: IkScopeStart, arg0: self.scope_tracker.to_value()))
    # Mark that we added a scope start, even for empty scopes
    self.scope_tracker.scope_started = true
    self.started_scope_depth.inc()

proc end_scope(self: Compiler) =
  if (self.module_init_mode or self.preserve_root_scope) and self.scope_trackers.len == 1:
    discard self.scope_trackers.pop()
    if self.declared_names.len > 0:
      discard self.declared_names.pop()
    return
  # If we added a ScopeStart (either because we have variables or we explicitly marked it),
  # we need to add the corresponding ScopeEnd
  let should_end = self.scope_tracker.next_index > 0 or self.scope_tracker.scope_started
  let should_pop_started_scope =
    self.scope_tracker.scope_started and not (self.skip_root_scope_start and self.scope_trackers.len == 1)
  if should_end:
    self.emit(Instruction(kind: IkScopeEnd))
    if should_pop_started_scope and self.started_scope_depth > 0:
      self.started_scope_depth.dec()
  discard self.scope_trackers.pop()
  if self.declared_names.len > 0:
    discard self.declared_names.pop()

proc compile_if(self: Compiler, gene: ptr Gene) =
  normalize_if(gene)

  self.start_scope()

  # Compile main condition
  self.compile(gene.props[COND_KEY.to_key()])
  var next_label = new_label()
  let end_label = new_label()
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: next_label.to_value()))

  # Compile then branch (preserves tail position)
  self.start_scope()
  let old_tail = self.tail_position
  self.compile(gene.props[THEN_KEY.to_key()])
  self.tail_position = old_tail
  self.end_scope()
  self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))

  # Handle elif branches if they exist
  if gene.props.has_key(ELIF_KEY.to_key()):
    let elifs = gene.props[ELIF_KEY.to_key()]
    case elifs.kind:
      of VkArray:
        # Process elif conditions and bodies in pairs
        let arr = array_data(elifs)
        for i in countup(0, arr.len - 1, 2):
          self.emit(Instruction(kind: IkNoop, label: next_label))
          
          if i < arr.len - 1:
            # Compile elif condition
            self.compile(arr[i])
            next_label = new_label()
            self.emit(Instruction(kind: IkJumpIfFalse, arg0: next_label.to_value()))
            
            # Compile elif body (preserves tail position)
            self.start_scope()
            let old_tail_elif = self.tail_position
            self.compile(arr[i + 1])
            self.tail_position = old_tail_elif
            self.end_scope()
            self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))
      else:
        discard

  # Compile else branch (preserves tail position)
  self.emit(Instruction(kind: IkNoop, label: next_label))
  self.start_scope()
  let old_tail_else = self.tail_position
  self.compile(gene.props[ELSE_KEY.to_key()])
  self.tail_position = old_tail_else
  self.end_scope()

  self.emit(Instruction(kind: IkNoop, label: end_label))

  self.end_scope()

proc compile_ifel(self: Compiler, gene: ptr Gene) =
  normalize_ifel(gene)
  self.compile_if(gene)

proc compile_if_not(self: Compiler, gene: ptr Gene) =
  normalize_if_not(gene)
  # After normalization, if_not has the same cond/then/else props as if.
  # compile_if's normalize_if will see "cond" already set and return early.
  self.compile_if(gene)

proc is_result_option_pattern(v: Value): bool =
  ## Check if value is a Result/Option pattern like (Ok a), (Err e), (Some x), or None
  if v.kind == VkSymbol and v.str == "None":
    return true
  if v.kind == VkGene and v.gene != nil:
    if v.gene.`type`.kind == VkSymbol:
      let type_name = v.gene.`type`.str
      if type_name in ["Ok", "Err", "Some", "None"]:
        return true
  return false

proc get_pattern_info(v: Value): tuple[type_name: string, binding: string] =
  ## Extract pattern info: type name and optional binding variable
  if v.kind == VkSymbol and v.str == "None":
    return ("None", "")
  if v.kind == VkGene and v.gene != nil:
    let type_name = v.gene.`type`.str
    var binding = ""
    if v.gene.children.len > 0 and v.gene.children[0].kind == VkSymbol:
      binding = v.gene.children[0].str
      if binding == "_":
        binding = ""  # _ means ignore binding
    return (type_name, binding)
  return ("", "")

proc compile_case(self: Compiler, gene: ptr Gene) =
  ## Compile case expression:
  ## (case target when val1 body1 when val2 body2 else body3)
  ##
  ## Supports pattern matching for Result/Option types:
  ## (case result
  ##   when (Ok value) (println value)
  ##   when (Err e) (println "error:" e)
  ## )
  ##
  ## Generates code that:
  ## 1. Evaluates target once
  ## 2. For each when: compare with value or pattern, jump to body if match
  ## 3. Fall through to else if no match

  normalize_case(gene)

  self.start_scope()

  let end_label = new_label()
  var next_label = new_label()

  # Get the normalized props
  let target = gene.props[CASE_TARGET_KEY.to_key()]
  let whens = gene.props[CASE_WHEN_KEY.to_key()]
  let else_body = gene.props[CASE_ELSE_KEY.to_key()]

  # Compile target and keep it on stack
  self.compile(target)

  # Process when clauses (stored as pairs: [value1, body1, value2, body2, ...])
  if whens.kind == VkArray:
    let arr = array_data(whens)
    var i = 0
    while i < arr.len:
      if i + 1 >= arr.len:
        break

      let when_value = arr[i]
      let when_body = arr[i + 1]

      # Label for this when clause
      if i > 0:
        self.emit(Instruction(kind: IkNoop, label: next_label))
        next_label = new_label()

      # Check if this is a Result/Option pattern
      if is_result_option_pattern(when_value):
        let (type_name, binding) = get_pattern_info(when_value)

        # Use pattern matching instruction
        # Stack: [target]
        self.emit(Instruction(kind: IkMatchGeneType, arg0: type_name.to_symbol_value()))
        # Stack: [target, bool]

        # Jump to next when if not matched
        self.emit(Instruction(kind: IkJumpIfFalse, arg0: next_label.to_value()))
        # Stack: [target]

        # Start scope for body with potential binding
        self.start_scope()

        # If there's a binding, extract the inner value and bind it
        if binding.len > 0:
          # Duplicate target to extract child
          self.emit(Instruction(kind: IkDup))
          # Stack: [target, target]
          self.emit(Instruction(kind: IkGetGeneChild, arg0: 0.to_value()))
          # Stack: [target, child]

          # Register the binding variable properly with numeric index
          let var_index = self.scope_tracker.next_index
          self.scope_tracker.mappings[binding.to_key()] = var_index
          self.add_scope_start()
          self.scope_tracker.next_index.inc()
          self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
          # Stack: [target, child] (IkVar doesn't pop)
          self.emit(Instruction(kind: IkPop))
          # Stack: [target]

        # Pop the target before executing body
        self.emit(Instruction(kind: IkPop))
        # Stack: []

        # Compile the when body
        let old_tail = self.tail_position
        self.compile(when_body)
        self.tail_position = old_tail
        self.end_scope()
      else:
        # Regular value comparison (original behavior)
        # Duplicate target for comparison
        self.emit(Instruction(kind: IkDup))

        # Compile the when value
        self.compile(when_value)

        # Compare: target == when_value
        self.emit(Instruction(kind: IkEq))

        # Jump to next when if not equal
        self.emit(Instruction(kind: IkJumpIfFalse, arg0: next_label.to_value()))

        # Pop the duplicated target before executing body
        self.emit(Instruction(kind: IkPop))

        # Compile the when body (preserves tail position)
        self.start_scope()
        let old_tail = self.tail_position
        self.compile(when_body)
        self.tail_position = old_tail
        self.end_scope()

      # Jump to end
      self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))

      i += 2

  # Else clause
  self.emit(Instruction(kind: IkNoop, label: next_label))

  # Pop the remaining target value before else body
  self.emit(Instruction(kind: IkPop))

  # Compile else body (preserves tail position)
  self.start_scope()
  let old_tail_else = self.tail_position
  self.compile(else_body)
  self.tail_position = old_tail_else
  self.end_scope()

  self.emit(Instruction(kind: IkNoop, label: end_label))

  self.end_scope()

proc compile_var(self: Compiler, gene: ptr Gene, immutable: bool = false) =
  if gene.children.len == 0:
    not_allowed((if immutable: "let" else: "var") & " requires a name")
  apply_container_to_child(gene, 0)
  let container_expr = gene.props.getOrDefault(container_key(), NIL)
  var explicit_type_id: TypeId = NO_TYPE_ID
  # Strip optional type annotation: (var x: Type value)
  if gene.children.len >= 2:
    let name_val = gene.children[0]
    if name_val.kind == VkSymbol and name_val.str.ends_with(":"):
      let base_name = name_val.str[0..^2].to_symbol_value()
      if gene.children.len > 1:
        explicit_type_id = resolve_type_value_to_id(gene.children[1], self.output.type_descriptors, self.output.type_aliases, self.output.module_path)
      gene.children[0] = base_name
      gene.children.delete(1) # Remove the type expression

  let name = gene.children[0]

  # Handle global variables like $x
  if name.kind == VkSymbol and name.str.starts_with("$") and name.str.len > 1 and name.str != "$ns":
    self.emit(Instruction(kind: IkPushValue, arg0: App.app.global_ns))
    if gene.children.len > 1:
      self.compile(gene.children[1])
    else:
      self.emit(Instruction(kind: IkPushValue, arg0: NIL))
    let global_key = name.str[1..^1].to_symbol_value()
    self.emit(Instruction(kind: IkSetMember, arg0: global_key))
    return

  # Handle namespace variables like $ns/a
  if name.kind == VkComplexSymbol:
    let parts = name.ref.csymbol
    if parts.len >= 2 and parts[0] == "$ns":
      # This is a namespace variable, store it directly in namespace
      if gene.children.len > 1:
        # Compile the value
        self.compile(gene.children[1])
      else:
        # No value, use NIL
        self.emit(Instruction(kind: IkPushValue, arg0: NIL))

      # Store in namespace
      let var_name = parts[1..^1].join("/")
      self.emit(Instruction(kind: IkNamespaceStore, arg0: var_name.to_symbol_value()))
      return

    # Handle class/instance variables like /table (which becomes ["", "table"])
    if parts.len >= 2 and parts[0] == "":
      # This is a class or instance variable, store it in namespace
      if gene.children.len > 1:
        # Compile the value
        self.compile(gene.children[1])
      else:
        # No value, use NIL
        self.emit(Instruction(kind: IkPushValue, arg0: NIL))

      # Store in namespace with the full name (e.g., "/table")
      let var_name = "/" & parts[1..^1].join("/")
      self.emit(Instruction(kind: IkNamespaceStore, arg0: var_name.to_symbol_value()))
      return

    # Handle namespace/class member variables like Record/orm
    # This stores a value in a namespace or class member
    if parts.len >= 2:
      # Resolve the first part (e.g., "Record")
      let key = parts[0].to_key()
      if self.scope_tracker.mappings.has_key(key):
        self.emit(Instruction(kind: IkVarResolve, arg0: self.scope_tracker.mappings[key].to_value()))
      else:
        self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](key)))

      # Navigate through intermediate parts if more than 2 parts
      for i in 1..<parts.len-1:
        let part_key = parts[i].to_key()
        self.emit(Instruction(kind: IkGetMember, arg0: cast[Value](part_key)))

      # Compile the value
      if gene.children.len > 1:
        self.compile(gene.children[1])
      else:
        self.emit(Instruction(kind: IkPushValue, arg0: NIL))

      # Set the final member (e.g., "orm")
      let last_key = parts[^1].to_key()
      self.emit(Instruction(kind: IkSetMember, arg0: last_key))
      return

  # Handle container expressions for variable declarations
  if container_expr != NIL:
    if name.kind != VkSymbol:
      not_allowed("Property variable name must resolve to a symbol")
    self.compile(container_expr)
    if gene.children.len > 1:
      self.compile(gene.children[1])
    else:
      self.emit(Instruction(kind: IkPushValue, arg0: NIL))
    self.emit(Instruction(kind: IkSetMember, arg0: name))
    return

  # Destructuring declarations: (var [a b] value), (var {^k ^v} value)
  if name.kind == VkArray:
    if gene.children.len > 1:
      self.compile(gene.children[1])
    else:
      self.emit(Instruction(kind: IkPushValue, arg0: NIL))

    # Use the same matcher semantics as function parameter binding.
    let matcher = new_arg_matcher(name)
    var target_indices = new_array_value()
    var has_bindings = false
    proc add_matcher_bindings(param: Matcher) =
      var bind_name = ""
      if cast[int64](param.name_key) != 0:
        try:
          bind_name = cast[Value](param.name_key).str
        except CatchableError:
          bind_name = ""

      if bind_name.len > 0 and bind_name != "_":
        let key = bind_name.to_key()
        let var_index = self.scope_tracker.next_index
        self.scope_tracker.mappings[key] = var_index
        self.scope_tracker.next_index.inc()
        if self.declared_names.len > 0:
          self.declared_names[^1][key] = true
        array_data(target_indices).add(var_index.to_value())
        has_bindings = true

      for child in param.children:
        add_matcher_bindings(child)

    for param in matcher.children:
      add_matcher_bindings(param)

    if has_bindings:
      self.add_scope_start()

    var payload = new_array_value()
    array_data(payload).add(name)
    array_data(payload).add(target_indices)
    self.emit(Instruction(kind: IkVarDestructure, arg0: payload))
    self.emit(Instruction(kind: IkPushNil))
    return

  if name.kind == VkMap:
    if gene.children.len > 1:
      self.compile(gene.children[1])
    else:
      self.emit(Instruction(kind: IkPushValue, arg0: NIL))

    # Keep one copy on stack while extracting each property.
    self.emit(Instruction(kind: IkDup))
    for key, value in map_data(name).pairs:
      if value.kind != VkSymbol:
        not_allowed("Unsupported map destructuring pattern: expected symbol bindings")

      var bind_name = value.str
      if bind_name.startsWith("^"):
        if bind_name.len <= 1:
          not_allowed("Unsupported map destructuring binding: '^' requires a name")
        bind_name = bind_name[1..^1]

      self.emit(Instruction(kind: IkDup))
      self.emit(Instruction(kind: IkPushValue, arg0: key.to_value()))
      self.emit(Instruction(kind: IkGetMemberOrNil))

      if bind_name == "_":
        self.emit(Instruction(kind: IkPop))
        continue

      let var_index = self.scope_tracker.next_index
      self.scope_tracker.mappings[bind_name.to_key()] = var_index
      self.add_scope_start()
      self.scope_tracker.next_index.inc()
      self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
      self.emit(Instruction(kind: IkPop))

    self.emit(Instruction(kind: IkPop))
    self.emit(Instruction(kind: IkPushNil))
    return

  # Regular variable handling
  if name.kind != VkSymbol:
    not_allowed("Variable name must be a symbol, got " & $name.kind)
    
  let key = name.str.to_key()
  var declared_here = false
  if self.declared_names.len > 0:
    declared_here = self.declared_names[^1].has_key(key)

  let has_mapping = self.scope_tracker.mappings.has_key(key)
  var old_index: int16
  if has_mapping:
    old_index = self.scope_tracker.mappings[key]
  let old_next_index = self.scope_tracker.next_index

  let use_existing = has_mapping and not declared_here
  var index: int16
  var new_binding = false
  if use_existing:
    # First declaration of a predeclared name in this scope.
    index = old_index
  else:
    # New binding (including shadowing an existing name in this scope).
    index = old_next_index
    new_binding = true

  var binding_type_id = explicit_type_id

  # Avoid resolving the new binding (and any new scope) inside its own initializer.
  if gene.children.len > 1:
    # For shadowing (new_binding when has_mapping): allocate new index but don't add mapping yet
    # so initializer captures parent scope
    if new_binding and has_mapping:
      # Shadowing case: compile initializer WITHOUT the new binding in scope
      self.scope_tracker.next_index = old_next_index
      self.compile(gene.children[1])
      # NOW add the new binding
      self.scope_tracker.mappings[key] = index
      self.scope_tracker.next_index = old_next_index + 1
    elif use_existing:
      # Pre-declared variable (e.g. module-level var): temporarily remove the
      # mapping while compiling the initializer so that inner functions
      # (closures) do NOT capture the variable being defined.  This allows
      # patterns like:
      #   (fn f [] 1)
      #   (var f (fn [] ((f) + 1)))   # inner f should resolve to namespace fn
      if self.local_definitions:
        # In local-def mode, keep the mapping so closures can capture locals
        # (e.g. recursive or forward-referenced local bindings).
        self.compile(gene.children[1])
      else:
        self.scope_tracker.mappings.del(key)
        self.scope_tracker.next_index = old_next_index
        self.compile(gene.children[1])
        # Restore the mapping after the initializer is compiled
        self.scope_tracker.mappings[key] = index
    else:
      # Normal case or redeclaration
      self.scope_tracker.next_index = old_next_index
      self.compile(gene.children[1])
      if new_binding:
        self.scope_tracker.mappings[key] = index
        self.scope_tracker.next_index = old_next_index + 1
    self.add_scope_start()
    set_expected_type_id(self.scope_tracker, index, binding_type_id)
    self.emit(Instruction(kind: IkVar, arg0: index.to_value(), arg1: binding_type_id))
  else:
    if new_binding:
      self.scope_tracker.mappings[key] = index
      self.scope_tracker.next_index = old_next_index + 1
    self.add_scope_start()
    set_expected_type_id(self.scope_tracker, index, binding_type_id)
    self.emit(Instruction(kind: IkVarValue, arg0: NIL, arg1: index))

  if not new_binding:
    self.scope_tracker.next_index = old_next_index

  if self.declared_names.len > 0:
    self.declared_names[^1][key] = true

  if immutable:
    self.scope_tracker.immutable_vars[key] = true

proc compile_container_assignment(self: Compiler, container_expr: Value, name_sym: Value, operator: string, rhs: Value) =
  if name_sym.kind != VkSymbol:
    not_allowed("Container assignment target must resolve to a symbol")
  let name_str = name_sym.str
  let (is_index, index) = to_int(name_str)
  let dynamic_member_span =
    if is_index:
      (matched: false, is_method: false, expr: NIL, next_index: 0)
    else:
      parse_dynamic_path_span([name_str], 0)
  let use_explicit_dynamic_member =
    dynamic_member_span.matched and
    dynamic_member_span.next_index == 1 and
    not dynamic_member_span.is_method
  let use_implicit_dynamic_member =
    (not is_index) and
    (not use_explicit_dynamic_member) and
    container_expr.kind == VkComplexSymbol and
    container_expr.ref.csymbol.len > 1 and
    not container_expr.ref.csymbol[^1].startsWith("_gene") and
    self.scope_tracker.locate(name_sym.str.to_key()).local_index >= 0
  let use_dynamic_member = use_explicit_dynamic_member or use_implicit_dynamic_member

  self.compile(container_expr)
  if operator == "=":
    if is_index:
      self.compile(rhs)
      self.emit(Instruction(kind: IkSetChild, arg0: index))
    elif use_dynamic_member:
      if use_explicit_dynamic_member:
        self.compile(dynamic_member_span.expr)
      else:
        self.compile(name_sym)
      self.compile(rhs)
      self.emit(Instruction(kind: IkSetMemberDynamic))
    else:
      self.compile(rhs)
      self.emit(Instruction(kind: IkSetMember, arg0: name_sym))
    return

  self.emit(Instruction(kind: IkDup))
  if is_index:
    self.emit(Instruction(kind: IkGetChild, arg0: index))
  elif use_dynamic_member:
    if use_explicit_dynamic_member:
      self.compile(dynamic_member_span.expr)
    else:
      self.compile(name_sym)
    self.emit(Instruction(kind: IkGetMemberOrNil))
  else:
    self.emit(Instruction(kind: IkGetMember, arg0: name_sym))

  self.compile(rhs)
  case operator:
    of "+=":
      self.emit(Instruction(kind: IkAdd))
    of "-=":
      self.emit(Instruction(kind: IkSub))
    of "%=":
      self.emit(Instruction(kind: IkMod))
    else:
      not_allowed("Unsupported compound assignment operator: " & operator)

  if is_index:
    self.emit(Instruction(kind: IkSetChild, arg0: index))
  elif use_dynamic_member:
    if use_explicit_dynamic_member:
      self.compile(dynamic_member_span.expr)
    else:
      self.compile(name_sym)
    self.emit(Instruction(kind: IkSwap))
    self.emit(Instruction(kind: IkSetMemberDynamic))
  else:
    self.emit(Instruction(kind: IkSetMember, arg0: name_sym))

proc compile_assignment(self: Compiler, gene: ptr Gene) =
  apply_container_to_type(gene)
  let `type` = gene.type
  let operator = gene.children[0].str
  let container_expr = gene.props.getOrDefault(container_key(), NIL)

  if operator == "=" and `type`.kind in {VkArray, VkMap}:
    let location = trace_location(gene.trace)
    let message = "destructuring assignment has been removed; use (var pattern value) and then assign explicitly"
    if location.len > 0:
      not_allowed(location & ": " & message)
    else:
      not_allowed(message)
  
  if `type`.kind == VkSymbol:
    # Check immutability for let bindings (walk scope chain)
    block:
      let assign_key = `type`.str.to_key()
      var tracker = self.scope_tracker
      while tracker != nil:
        if tracker.immutable_vars.hasKey(assign_key):
          not_allowed("Cannot reassign 'let' binding '" & `type`.str & "'")
        tracker = tracker.parent

    if `type`.str.starts_with("$") and `type`.str.len > 1 and `type`.str != "$ns":
      let name_sym = `type`.str[1..^1].to_symbol_value()
      self.compile_container_assignment(App.app.global_ns, name_sym, operator, gene.children[1])
      return
    if container_expr != NIL:
      self.compile_container_assignment(container_expr, `type`, operator, gene.children[1])
      return
    # For compound assignment, we need to load the current value first
    if operator != "=":
      let key = `type`.str.to_key()
      let found = self.scope_tracker.locate(key)
      let rhs = gene.children[1]

      # Fast path: (x += 1) → IkIncVar, (x -= 1) → IkDecVar
      if found.local_index >= 0 and found.parent_index == 0 and
         rhs.kind == VkInt and rhs.int64 == 1:
        if operator == "+=":
          self.emit(Instruction(kind: IkIncVar, arg0: found.local_index.to_value()))
          return
        elif operator == "-=":
          self.emit(Instruction(kind: IkDecVar, arg0: found.local_index.to_value()))
          return

      if found.local_index >= 0:
        if found.parent_index == 0:
          self.emit(Instruction(kind: IkVarResolve, arg0: found.local_index.to_value()))
        else:
          self.emit(Instruction(kind: IkVarResolveInherited, arg0: found.local_index.to_value(), arg1: found.parent_index))
      else:
        self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](key)))
      
      # Compile the right-hand side value
      self.compile(gene.children[1])
      
      # Apply the operation
      case operator:
        of "+=":
          self.emit(Instruction(kind: IkAdd))
        of "-=":
          self.emit(Instruction(kind: IkSub))
        of "*=":
          self.emit(Instruction(kind: IkMul))
        of "/=":
          self.emit(Instruction(kind: IkDiv))
        of "%=":
          self.emit(Instruction(kind: IkMod))
        else:
          not_allowed("Unsupported compound assignment operator: " & operator)
    else:
      # Regular assignment - check for increment/decrement pattern
      let rhs = gene.children[1]
      let key = `type`.str.to_key()
      let found = self.scope_tracker.locate(key)
      
      # Check for (x = (x + 1)) or (x = (x - 1)) pattern
      # In infix notation: (x + 1) has type=x and children=[+, 1]
      if found.local_index >= 0 and found.parent_index == 0 and
         rhs.kind == VkGene and rhs.gene.children.len == 2:
        let rhs_gene = rhs.gene
        let op = rhs_gene.children[0]
        let rhs_operand = rhs_gene.children[1]
        
        # Check if it's (x + 1) or (x - 1) where x is the gene type
        if rhs_gene.type.kind == VkSymbol and rhs_gene.type.str == `type`.str and
           op.kind == VkSymbol and rhs_operand.kind == VkInt:
          if op.str == "+" and rhs_operand.int64 == 1:
            # Generate IkIncVar instead
            self.emit(Instruction(kind: IkIncVar, arg0: found.local_index.to_value()))
            return
          elif op.str == "-" and rhs_operand.int64 == 1:
            # Generate IkDecVar instead
            self.emit(Instruction(kind: IkDecVar, arg0: found.local_index.to_value()))
            return
      
      # Regular assignment - compile the value
      self.compile(gene.children[1])
    
    # Store the result
    let key = `type`.str.to_key()
    let found = self.scope_tracker.locate(key)
    if found.local_index >= 0:
      if found.parent_index == 0:
        self.emit(Instruction(kind: IkVarAssign, arg0: found.local_index.to_value()))
      else:
        self.emit(Instruction(kind: IkVarAssignInherited, arg0: found.local_index.to_value(), arg1: found.parent_index))
    else:
      self.emit(Instruction(kind: IkAssign, arg0: `type`))
  elif `type`.kind == VkComplexSymbol:
    let r = translate_symbol(`type`).ref
    let key = r.csymbol[0].to_key()
    let last_segment = r.csymbol[^1]
    let (last_is_int, last_index) = to_int(last_segment)
    let dynamic_last_span =
      if last_is_int:
        (matched: false, is_method: false, expr: NIL, next_index: 0)
      else:
        parse_dynamic_path_span(r.csymbol, r.csymbol.len - 1)
    let use_explicit_dynamic_last_segment =
      dynamic_last_span.matched and
      dynamic_last_span.next_index == r.csymbol.len and
      not dynamic_last_span.is_method
    let use_implicit_dynamic_last_segment =
      (not last_is_int) and
      (not use_explicit_dynamic_last_segment) and
      r.csymbol.len > 2 and
      not r.csymbol[^2].startsWith("_gene") and
      self.scope_tracker.locate(last_segment.to_key()).local_index >= 0
    let use_dynamic_last_segment = use_explicit_dynamic_last_segment or use_implicit_dynamic_last_segment
    
    # Load the target object first (for both regular and compound assignment)
    if r.csymbol[0] == "SPECIAL_NS":
      self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](SYM_NS)))
    elif r.csymbol[0] == "SPECIAL_GLOBAL":
      self.emit(Instruction(kind: IkPushValue, arg0: App.app.global_ns))
    else:
      let found = self.scope_tracker.locate(key)
      if found.local_index >= 0:
        if found.parent_index == 0:
          self.emit(Instruction(kind: IkVarResolve, arg0: found.local_index.to_value()))
        else:
          self.emit(Instruction(kind: IkVarResolveInherited, arg0: found.local_index.to_value(), arg1: found.parent_index))
      elif r.csymbol[0] == "self":
        self.emit(Instruction(kind: IkSelf))
      else:
        self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](key)))
      
    # Navigate to parent object (if nested property access)
    if r.csymbol.len > 2:
      for s in r.csymbol[1..^2]:
        let (is_int, i) = to_int(s)
        if is_int:
          self.emit(Instruction(kind: IkGetChild, arg0: i))
        elif s.starts_with("."):
          let method_value = s[1..^1].to_symbol_value()
          self.emit(Instruction(kind: IkResolveMethod, arg0: method_value))
          self.emit(Instruction(kind: IkUnifiedMethodCall0, arg0: method_value))
        else:
          let key = s.to_key()
          self.emit(Instruction(kind: IkGetMember, arg0: cast[Value](key)))
    
    if operator != "=":
      # For compound assignment, duplicate the target object on the stack
      # Stack: [target] -> [target, target]
      self.emit(Instruction(kind: IkDup))
      
      # Get current value
      if last_is_int:
        self.emit(Instruction(kind: IkGetChild, arg0: last_index))
      elif use_dynamic_last_segment:
        if use_explicit_dynamic_last_segment:
          self.compile(dynamic_last_span.expr)
        else:
          self.compile(last_segment.to_symbol_value())
        self.emit(Instruction(kind: IkGetMemberOrNil))
      else:
        self.emit(Instruction(kind: IkGetMember, arg0: last_segment.to_key()))
      
      # Compile the right-hand side value
      self.compile(gene.children[1])
      
      # Apply the operation
      case operator:
        of "+=":
          self.emit(Instruction(kind: IkAdd))
        of "-=":
          self.emit(Instruction(kind: IkSub))
        of "*=":
          self.emit(Instruction(kind: IkMul))
        of "/=":
          self.emit(Instruction(kind: IkDiv))
        of "%=":
          self.emit(Instruction(kind: IkMod))
        else:
          not_allowed("Unsupported compound assignment operator: " & operator)
      
      # Now stack should be: [target, new_value]
      # Set the property
      if last_is_int:
        self.emit(Instruction(kind: IkSetChild, arg0: last_index))
      elif use_dynamic_last_segment:
        if use_explicit_dynamic_last_segment:
          self.compile(dynamic_last_span.expr)
        else:
          self.compile(last_segment.to_symbol_value())
        self.emit(Instruction(kind: IkSwap))
        self.emit(Instruction(kind: IkSetMemberDynamic))
      else:
        self.emit(Instruction(kind: IkSetMember, arg0: last_segment.to_key()))
    else:
      # Regular assignment
      if last_is_int:
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkSetChild, arg0: last_index))
      elif use_dynamic_last_segment:
        if use_explicit_dynamic_last_segment:
          self.compile(dynamic_last_span.expr)
        else:
          self.compile(last_segment.to_symbol_value())
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkSetMemberDynamic))
      else:
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkSetMember, arg0: last_segment.to_key()))
  else:
    not_allowed($`type`)

proc get_loop_name(gene: ptr Gene): string =
  let name_key = "name".to_key()
  if gene.props.has_key(name_key):
    let name_val = gene.props[name_key]
    if name_val.kind == VkSymbol:
      return name_val.str
    elif name_val.kind == VkString:
      return name_val.str
  return ""

proc compile_loop(self: Compiler, gene: ptr Gene) =
  let start_label = new_label()
  let end_label = new_label()
  
  # Track this loop
  self.loop_stack.add(LoopInfo(start_label: start_label, end_label: end_label, scope_depth: self.started_scope_depth, name: get_loop_name(gene)))
  
  self.emit(Instruction(kind: IkLoopStart, label: start_label))
  self.compile(gene.children, true)
  self.emit(Instruction(kind: IkContinue, arg0: start_label.to_value()))
  self.emit(Instruction(kind: IkLoopEnd, label: end_label))
  
  # Pop loop from stack
  discard self.loop_stack.pop()

proc compile_while(self: Compiler, gene: ptr Gene) =
  if gene.children.len < 1:
    not_allowed("while expects at least 1 argument (condition)")
  
  let label = new_label()
  let end_label = new_label()
  
  # Track this loop
  self.loop_stack.add(LoopInfo(start_label: label, end_label: end_label, scope_depth: self.started_scope_depth, name: get_loop_name(gene)))
  
  # Mark loop start
  self.emit(Instruction(kind: IkLoopStart, label: label))
  
  # Compile and test condition
  self.compile(gene.children[0])
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: end_label.to_value()))
  
  # Compile body (remaining children)
  if gene.children.len > 1:
    # Use the seq compile method which handles popping correctly
    let body = gene.children[1..^1]
    self.compile(body, true)
    # Pop the final value from the loop body since we don't need it
    if body.len > 0 and not is_vmstmt_form(body[^1]):
      self.emit(Instruction(kind: IkPop))
  
  # Jump back to condition
  self.emit(Instruction(kind: IkContinue, arg0: label.to_value()))
  
  # Mark loop end
  self.emit(Instruction(kind: IkLoopEnd, label: end_label))
  
  # Push NIL as the result of the while loop
  self.emit(Instruction(kind: IkPushNil))
  
  # Pop loop from stack
  discard self.loop_stack.pop()

proc compile_repeat(self: Compiler, gene: ptr Gene) =
  if gene.children.len < 1:
    not_allowed("repeat expects at least 1 argument (count)")
  
  # For now, implement a simple version without index/total variables
  if gene.props.has_key(INDEX_KEY.to_key()) or gene.props.has_key(TOTAL_KEY.to_key()):
    not_allowed("repeat with index/total variables not yet implemented in VM")
  
  let start_label = new_label()
  let end_label = new_label()
  
  # Compile count expression
  self.compile(gene.children[0])

  # Initialize repeat loop
  self.emit(Instruction(kind: IkRepeatInit, arg0: end_label.to_value()))

  # Track this loop (baseline is after evaluating the count expression)
  self.loop_stack.add(LoopInfo(start_label: start_label, end_label: end_label, scope_depth: self.started_scope_depth, name: get_loop_name(gene)))

  # Mark the start of loop body
  self.emit(Instruction(kind: IkNoop, label: start_label))

  if gene.children.len > 1:
    self.start_scope()
    for i in 1..<gene.children.len:
      let child = gene.children[i]
      if is_vmstmt_form(child):
        self.compile_vmstmt(child.gene)
      else:
        self.compile(child)
        self.emit(Instruction(kind: IkPop))
    self.end_scope()

  self.emit(Instruction(kind: IkRepeatDecCheck, arg0: start_label.to_value()))

  # Push nil as the result, mark loop end
  self.emit(Instruction(kind: IkPushNil, label: end_label))
  
  # Pop loop from stack
  discard self.loop_stack.pop()

proc compile_for(self: Compiler, gene: ptr Gene) =
  # Supported forms:
  #   (for x in collection body...)         - value only
  #   (for i x in collection body...)       - index/key + value
  #   (for k [a b] in collection body...)   - key + destructured value
  if gene.children.len < 2:
    not_allowed("for expects at least 2 arguments (variable and collection)")

  # Find the position of 'in' keyword to determine the form
  var in_pos = -1
  for i in 0..<min(gene.children.len, 4):  # 'in' can be at position 1, 2, or 3 at most
    if gene.children[i].kind == VkSymbol and gene.children[i].str == "in":
      in_pos = i
      break

  if in_pos < 1 or in_pos + 1 >= gene.children.len:
    not_allowed("for loop requires 'in' keyword followed by a collection")

  var pair_name: string = ""
  var use_pair_iteration = false
  var value_pattern: Value = NIL

  case in_pos
  of 1:
    # (for x in ...) or (for [a b] in ...) or (for {^x x} in ...)
    let var_node = gene.children[0]
    case var_node.kind
    of VkSymbol:
      value_pattern = var_node
    of VkArray:
      # Destructuring pattern for value, e.g. (for [a b] in ...)
      value_pattern = var_node
    of VkMap:
      # Destructuring map pattern for value
      value_pattern = var_node
    else:
      not_allowed("for loop variable must be a symbol or destructuring pattern")
  of 2:
    # (for i x in ...) or (for k [a b] in ...) or (for k {^x x} in ...)
    let key_node = gene.children[0]
    let val_node = gene.children[1]
    if key_node.kind != VkSymbol:
      not_allowed("for loop index/key binding must be a symbol")
    pair_name = key_node.str
    use_pair_iteration = true
    if val_node.kind notin {VkSymbol, VkArray, VkMap}:
      not_allowed("for loop value binding must be a symbol or destructuring pattern")
    value_pattern = val_node
  else:
    not_allowed("for loop: unexpected tokens before 'in'")

  if value_pattern == NIL:
    not_allowed("for loop requires a value binding pattern")
  let collection = gene.children[in_pos + 1]
  let body_start = in_pos + 2
  let iter_method = "iter".to_symbol_value()
  let next_method = "next".to_symbol_value()
  let next_pair_method = "next_pair".to_symbol_value()
  let iterator_key = "$for_iterator".to_key()
  let item_key = "$for_item".to_key()

  proc bind_value_on_stack(pattern: Value) =
    case pattern.kind
    of VkSymbol:
      let var_name = pattern.str
      if var_name != "_":
        let var_index = self.scope_tracker.next_index
        self.scope_tracker.mappings[var_name.to_key()] = var_index
        if self.declared_names.len > 0:
          self.declared_names[^1][var_name.to_key()] = true
        self.add_scope_start()
        self.scope_tracker.next_index.inc()
        self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
        self.emit(Instruction(kind: IkPop))
      else:
        self.emit(Instruction(kind: IkPop))
    of VkArray:
      let matcher = new_arg_matcher(pattern)
      var target_indices = new_array_value()
      var has_bindings = false

      proc add_matcher_bindings(param: Matcher) =
        var bind_name = ""
        if cast[int64](param.name_key) != 0:
          try:
            bind_name = cast[Value](param.name_key).str
          except CatchableError:
            bind_name = ""

        if bind_name.len > 0 and bind_name != "_":
          let key = bind_name.to_key()
          let var_index = self.scope_tracker.next_index
          self.scope_tracker.mappings[key] = var_index
          self.scope_tracker.next_index.inc()
          if self.declared_names.len > 0:
            self.declared_names[^1][key] = true
          array_data(target_indices).add(var_index.to_value())
          has_bindings = true

        for child in param.children:
          add_matcher_bindings(child)

      for param in matcher.children:
        add_matcher_bindings(param)

      if has_bindings:
        self.add_scope_start()

      var payload = new_array_value()
      array_data(payload).add(pattern)
      array_data(payload).add(target_indices)
      self.emit(Instruction(kind: IkVarDestructure, arg0: payload))
    of VkMap:
      self.emit(Instruction(kind: IkDup))
      for key, value in map_data(pattern).pairs:
        if value.kind != VkSymbol:
          not_allowed("Unsupported map destructuring pattern: expected symbol bindings")

        var bind_name = value.str
        if bind_name.startsWith("^"):
          if bind_name.len <= 1:
            not_allowed("Unsupported map destructuring binding: '^' requires a name")
          bind_name = bind_name[1..^1]

        self.emit(Instruction(kind: IkDup))
        self.emit(Instruction(kind: IkPushValue, arg0: key.to_value()))
        self.emit(Instruction(kind: IkGetMemberOrNil))

        if bind_name == "_":
          self.emit(Instruction(kind: IkPop))
          continue

        let var_index = self.scope_tracker.next_index
        self.scope_tracker.mappings[bind_name.to_key()] = var_index
        if self.declared_names.len > 0:
          self.declared_names[^1][bind_name.to_key()] = true
        self.add_scope_start()
        self.scope_tracker.next_index.inc()
        self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
        self.emit(Instruction(kind: IkPop))

      self.emit(Instruction(kind: IkPop))
    else:
      not_allowed("Unsupported for loop binding pattern")
  
  # Create a scope for the entire for loop to hold temporary variables
  self.start_scope()
  
  # Store iterator in a temporary variable
  self.compile(collection)
  self.emit(Instruction(kind: IkUnifiedMethodCall0, arg0: iter_method))
  let iterator_index = self.scope_tracker.next_index
  self.scope_tracker.mappings[iterator_key] = iterator_index
  self.add_scope_start()
  self.scope_tracker.next_index.inc()
  self.emit(Instruction(kind: IkVar, arg0: iterator_index.to_value()))
  self.emit(Instruction(kind: IkPop))

  # Store current loop item / pair in a temporary variable
  self.emit(Instruction(kind: IkPushNil))
  let item_index = self.scope_tracker.next_index
  self.scope_tracker.mappings[item_key] = item_index
  self.add_scope_start()
  self.scope_tracker.next_index.inc()
  self.emit(Instruction(kind: IkVar, arg0: item_index.to_value()))
  self.emit(Instruction(kind: IkPop))
  
  let start_label = new_label()
  let end_label = new_label()
  
  # Track this loop
  self.loop_stack.add(LoopInfo(start_label: start_label, end_label: end_label, scope_depth: self.started_scope_depth, name: get_loop_name(gene)))
  
  # Mark loop start
  self.emit(Instruction(kind: IkLoopStart, label: start_label))
  
  # Pull next loop value from the iterator and stop on NOT_FOUND.
  self.emit(Instruction(kind: IkVarResolve, arg0: iterator_index.to_value()))
  self.emit(Instruction(kind: if use_pair_iteration: IkUnifiedMethodCall0 else: IkUnifiedMethodCall0,
    arg0: if use_pair_iteration: next_pair_method else: next_method))
  self.emit(Instruction(kind: IkVarAssign, arg0: item_index.to_value()))
  self.emit(Instruction(kind: IkPop))
  self.emit(Instruction(kind: IkVarResolve, arg0: item_index.to_value()))
  self.emit(Instruction(kind: IkPushValue, arg0: NOT_FOUND))
  self.emit(Instruction(kind: IkNe))
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: end_label.to_value()))

  # Create scope for loop iteration
  self.start_scope()

  proc emit_temp_resolve(key: Key) =
    let found = self.scope_tracker.locate(key)
    if found.local_index < 0:
      not_allowed("for loop temporary binding not found")
    if found.parent_index == 0:
      self.emit(Instruction(kind: IkVarResolve, arg0: found.local_index.to_value()))
    else:
      self.emit(Instruction(kind: IkVarResolveInherited, arg0: found.local_index.to_value(), arg1: found.parent_index))

  if use_pair_iteration:
    if pair_name.len > 0 and pair_name != "_":
      emit_temp_resolve(item_key)
      self.emit(Instruction(kind: IkPushValue, arg0: 0.to_value()))
      self.emit(Instruction(kind: IkGetChildDynamic))
      let pair_var_index = self.scope_tracker.next_index
      self.scope_tracker.mappings[pair_name.to_key()] = pair_var_index
      if self.declared_names.len > 0:
        self.declared_names[^1][pair_name.to_key()] = true
      self.add_scope_start()
      self.scope_tracker.next_index.inc()
      self.emit(Instruction(kind: IkVar, arg0: pair_var_index.to_value()))
      self.emit(Instruction(kind: IkPop))

    emit_temp_resolve(item_key)
    self.emit(Instruction(kind: IkPushValue, arg0: 1.to_value()))
    self.emit(Instruction(kind: IkGetChildDynamic))
    bind_value_on_stack(value_pattern)
  else:
    emit_temp_resolve(item_key)
    bind_value_on_stack(value_pattern)
  
  # Compile body (remaining children after 'in' and collection)
  if gene.children.len > body_start:
    for i in body_start..<gene.children.len:
      let child = gene.children[i]
      if is_vmstmt_form(child):
        self.compile_vmstmt(child.gene)
      else:
        self.compile(child)
        # Pop the result (we don't need it)
        self.emit(Instruction(kind: IkPop))
  
  # End the iteration scope
  self.end_scope()
  
  # Jump back to condition check
  self.emit(Instruction(kind: IkContinue, arg0: start_label.to_value()))
  
  # Mark loop end
  self.emit(Instruction(kind: IkLoopEnd, label: end_label))
  
  # End the for loop scope
  self.end_scope()
  
  # Push nil as the result
  self.emit(Instruction(kind: IkPushNil))
  
  # Pop loop from stack
  discard self.loop_stack.pop()

type EnumVariantCompileMetadata = object
  name: string
  value: int
  fields: seq[string]
  field_type_ids: seq[TypeId]

proc string_array_value(items: seq[string]): Value =
  var values: seq[Value] = @[]
  for item in items:
    values.add(item.to_value())
  new_array_value(values)

proc type_id_array_value(items: seq[TypeId]): Value =
  var values: seq[Value] = @[]
  for item in items:
    values.add(item.int.to_value())
  new_array_value(values)

proc parse_enum_declaration_name(raw_name: string): tuple[base_name: string, type_params: seq[string]] =
  let parsed = split_generic_definition_name(raw_name)
  if raw_name.contains(":") and (parsed.base_name == raw_name or parsed.type_params.len == 0):
    not_allowed("enum generic declaration '" & raw_name & "' has invalid generic parameter syntax")
  result.base_name = parsed.base_name
  result.type_params = parsed.type_params
  if result.base_name.len == 0:
    not_allowed("enum name must not be empty")

  var seen_params = initTable[string, bool]()
  for param in result.type_params:
    if seen_params.hasKey(param):
      not_allowed("enum " & result.base_name & " has duplicate generic parameter " & param)
    seen_params[param] = true

proc enum_type_annotation_valid(v: Value): bool =
  case v.kind
  of VkSymbol, VkString:
    return v.str.len > 0 and not v.str.endsWith(":")
  of VkGene:
    return v.gene != nil and (v.gene.type.kind == VkSymbol or v.gene.type.kind == VkString)
  else:
    return false

proc parse_enum_variant_fields(self: Compiler, enum_name: string, variant_gene: ptr Gene,
                               type_desc_index: var Table[string, TypeId],
                               generic_type_ids: Table[string, TypeId]): tuple[fields: seq[string], field_type_ids: seq[TypeId]] =
  let variant_name = variant_gene.type.str
  if variant_gene.props.len > 0:
    not_allowed("enum variant " & enum_name & "/" & variant_name & " field declarations must be positional, not properties")

  var seen_fields = initTable[string, bool]()
  var i = 0
  while i < variant_gene.children.len:
    let child = variant_gene.children[i]
    if child.kind != VkSymbol:
      not_allowed("enum variant " & enum_name & "/" & variant_name & " field must be a symbol")

    let token = child.str
    var field_name = token
    var field_type_id = NO_TYPE_ID

    if token.endsWith(":"):
      field_name = token[0..^2]
      if field_name.len == 0:
        not_allowed("enum variant " & enum_name & "/" & variant_name & " has an empty field name")
      if i + 1 >= variant_gene.children.len:
        not_allowed("enum variant " & enum_name & "/" & variant_name & " field " & field_name & " is missing a type after ':'")
      let type_node = variant_gene.children[i + 1]
      if type_node.kind == VkSymbol and type_node.str.endsWith(":"):
        not_allowed("enum variant " & enum_name & "/" & variant_name & " field " & field_name & " is missing a type after ':'")
      if not enum_type_annotation_valid(type_node):
        not_allowed("enum variant " & enum_name & "/" & variant_name & " field " & field_name & " has an invalid type annotation")
      field_type_id = resolve_type_value_to_id_with_index(
        type_node, self.output.type_descriptors, type_desc_index, self.output.type_aliases,
        generic_type_ids, self.output.module_path)
      i += 2
    else:
      i.inc()

    if seen_fields.hasKey(field_name):
      not_allowed("enum variant " & enum_name & "/" & variant_name & " has duplicate field " & field_name)
    seen_fields[field_name] = true
    result.fields.add(field_name)
    result.field_type_ids.add(field_type_id)

proc compile_enum(self: Compiler, gene: ptr Gene) =
  # (enum Color red green blue)
  # (enum Status ^values [ok error pending])
  # (enum Result:T:E (Ok value: T) (Err error: E))
  if gene.children.len < 1:
    not_allowed("enum expects at least a name")
  
  let name_node = gene.children[0]
  if name_node.kind != VkSymbol:
    not_allowed("enum name must be a symbol")
  
  let parsed_name = parse_enum_declaration_name(name_node.str)
  let enum_name = parsed_name.base_name
  let type_params = parsed_name.type_params

  var type_desc_index = initTable[string, TypeId]()
  ensure_type_desc_index(self.output.type_descriptors, type_desc_index)
  var generic_type_ids = initTable[string, TypeId]()
  for i, param in type_params:
    let type_id = intern_type_desc(self.output.type_descriptors,
      TypeDesc(module_path: self.output.module_path, kind: TdkVar, var_id: i.int32),
      type_desc_index)
    generic_type_ids[param] = type_id

  var variants: seq[EnumVariantCompileMetadata] = @[]
  var seen_variants = initTable[string, bool]()

  proc add_variant(variant: EnumVariantCompileMetadata) =
    if seen_variants.hasKey(variant.name):
      not_allowed("enum " & enum_name & " has duplicate variant " & variant.name)
    seen_variants[variant.name] = true
    variants.add(variant)
  
  if gene.props.has_key("values".to_key()):
    # Values are provided in the ^values property
    let values_array = gene.props["values".to_key()]
    if values_array.kind != VkArray:
      not_allowed("enum ^values must be an array")
    
    var value = 0
    for member in array_data(values_array):
      if member.kind != VkSymbol:
        not_allowed("enum ^values member must be a symbol")
      add_variant(EnumVariantCompileMetadata(
        name: member.str,
        value: value,
        fields: @[],
        field_type_ids: @[]))
      value.inc()
  else:
    # Members are provided as children
    var value = 0
    var i = 1
    while i < gene.children.len:
      let member = gene.children[i]
      if member.kind == VkSymbol:
        let variant_name = member.str
        # Unit variant: (enum Color red green blue)
        # Check if next child is '=' for custom value
        if i + 2 < gene.children.len and
           gene.children[i + 1].kind == VkSymbol and
           gene.children[i + 1].str == "=":
          # Custom value provided
          i += 2
          if gene.children[i].kind != VkInt:
            not_allowed("enum member " & variant_name & " value must be an integer")
          value = gene.children[i].int64.int

        add_variant(EnumVariantCompileMetadata(
          name: variant_name,
          value: value,
          fields: @[],
          field_type_ids: @[]))
      elif member.kind == VkGene:
        # Data variant: (Circle radius) or (Rect width: Int height: Int)
        let variant_gene = member.gene
        if variant_gene.type.kind != VkSymbol:
          not_allowed("enum data variant name must be a symbol")
        let variant_name = variant_gene.type.str
        let parsed_fields = self.parse_enum_variant_fields(enum_name, variant_gene, type_desc_index, generic_type_ids)
        add_variant(EnumVariantCompileMetadata(
          name: variant_name,
          value: value,
          fields: parsed_fields.fields,
          field_type_ids: parsed_fields.field_type_ids))
      else:
        not_allowed("enum member must be a symbol or data variant (Name field1 field2)")

      value.inc()
      i.inc()
  
  # Create the enum after validation so malformed declarations fail before bytecode emission.
  self.emit(Instruction(
    kind: IkPushValue,
    arg0: enum_name.to_value()))
  self.emit(Instruction(
    kind: IkCreateEnum,
    arg0: string_array_value(type_params)))

  for variant in variants:
    var field_values: seq[Value] = @[]
    for field in variant.fields:
      field_values.add(field.to_value())
    self.emit(Instruction(kind: IkPushValue, arg0: variant.name.to_value()))
    self.emit(Instruction(kind: IkPushValue, arg0: variant.value.to_value()))
    self.emit(Instruction(kind: IkPushValue, arg0: new_array_value(field_values)))
    self.emit(Instruction(kind: IkEnumAddMember, arg0: type_id_array_value(variant.field_type_ids)))
  
  # Store the enum in the namespace under its canonical base name.
  let index = self.scope_tracker.next_index
  self.scope_tracker.mappings[enum_name.to_key()] = index
  self.add_scope_start()
  self.scope_tracker.next_index.inc()
  self.emit(Instruction(kind: IkVar, arg0: index.to_value()))

proc find_loop(self: Compiler, gene: ptr Gene): LoopInfo =
  ## Find the target loop — innermost by default, or by ^from name
  let from_key = "from".to_key()
  if gene.props.has_key(from_key):
    let from_val = gene.props[from_key]
    var target_name = ""
    if from_val.kind == VkSymbol:
      target_name = from_val.str
    elif from_val.kind == VkString:
      target_name = from_val.str
    else:
      not_allowed("^from must be a symbol or string")
    # Search loop stack from innermost to outermost
    for i in countdown(self.loop_stack.len - 1, 0):
      if self.loop_stack[i].name == target_name:
        return self.loop_stack[i]
    not_allowed("No loop named '" & target_name & "' found")
  else:
    if self.loop_stack.len == 0:
      not_allowed("break/continue outside of loop")
    return self.loop_stack[^1]

proc compile_break(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    self.compile(gene.children[0])
  else:
    self.emit(Instruction(kind: IkPushNil))

  if self.loop_stack.len == 0:
    self.emit(Instruction(kind: IkBreak, arg0: (-1).to_value()))
  else:
    let target_loop = self.find_loop(gene)
    let unwind_count = self.started_scope_depth.int - target_loop.scope_depth.int
    if unwind_count > 0:
      for _ in 0..<unwind_count:
        self.emit(Instruction(kind: IkScopeEnd))
    self.emit(Instruction(kind: IkBreak, arg0: target_loop.end_label.to_value()))

proc compile_continue(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    self.compile(gene.children[0])
  else:
    self.emit(Instruction(kind: IkPushNil))

  if self.loop_stack.len == 0:
    self.emit(Instruction(kind: IkContinue, arg0: (-1).to_value()))
  else:
    let target_loop = self.find_loop(gene)
    let unwind_count = self.started_scope_depth.int - target_loop.scope_depth.int
    if unwind_count > 0:
      for _ in 0..<unwind_count:
        self.emit(Instruction(kind: IkScopeEnd))
    self.emit(Instruction(kind: IkContinue, arg0: target_loop.start_label.to_value()))

proc compile_throw(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    # Throw with a value
    self.compile(gene.children[0])
  else:
    # Throw without a value (re-throw current exception)
    self.emit(Instruction(kind: IkPushNil))
  self.emit(Instruction(kind: IkThrow))

proc compile_try(self: Compiler, gene: ptr Gene) =
  let catch_end_label = new_label()
  let finally_label = new_label()
  let end_label = new_label()
  
  # Check if there's a finally block
  var has_finally = false
  var finally_idx = -1
  for idx in 0..<gene.children.len:
    if gene.children[idx].kind == VkSymbol and gene.children[idx].str == "finally":
      has_finally = true
      finally_idx = idx
      break
  
  # Mark start of try block
  # If we have a finally, catch handler should point to finally_label
  if has_finally:
    self.emit(Instruction(kind: IkTryStart, arg0: catch_end_label.to_value(), arg1: finally_label))
  else:
    self.emit(Instruction(kind: IkTryStart, arg0: catch_end_label.to_value()))
  
  # Compile try body
  var i = 0
  while i < gene.children.len:
    let child = gene.children[i]
    if child.kind == VkSymbol and (child.str == "catch" or child.str == "finally"):
      break
    self.compile(child)
    inc i
  
  # Mark end of try block
  self.emit(Instruction(kind: IkTryEnd))
  
  # If we have a finally block, we need to preserve the try block's value
  if has_finally:
    # The try block's value is on the stack - we'll handle it in the finally section
    self.emit(Instruction(kind: IkJump, arg0: finally_label.to_value()))
  else:
    self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))
  
  # Handle catch blocks
  self.emit(Instruction(kind: IkNoop, label: catch_end_label))
  var catch_count = 0
  while i < gene.children.len:
    let child = gene.children[i]
    if child.kind == VkSymbol and child.str == "catch":
      inc i
      if i < gene.children.len:
        # Get the catch pattern
        let pattern = gene.children[i]
        inc i
        
        var next_catch_label: Label
        let is_symbol_pattern = pattern.kind == VkSymbol
        let is_catch_all = is_symbol_pattern and pattern.str == "*"
        # catch ex / catch err => bind exception to a variable.
        # Uppercase symbol catches remain type-based (e.g. catch MyError).
        let is_symbol_binding =
          is_symbol_pattern and
          pattern.str.len > 0 and
          pattern.str != "*" and
          (pattern.str == "_" or pattern.str[0].isLowerAscii())
        # Destructuring patterns in catch reuse var-binding semantics.
        let is_destructure_binding = pattern.kind in {VkArray, VkMap}
        let is_catch_binding = is_symbol_binding or is_destructure_binding
        
        # Generate catch matching code
        if is_catch_all or is_catch_binding:
          # Catch all - no need to check type
          self.emit(Instruction(kind: IkCatchStart))
        else:
          # Type-specific catch
          next_catch_label = new_label()
          
          # Check if exception matches this type
          self.emit(Instruction(kind: IkCatchStart))
          
          # Load the current exception and check its type
          self.emit(Instruction(kind: IkPushValue, arg0: App.app.gene_ns))
          self.emit(Instruction(kind: IkGetMember, arg0: "ex".to_key().to_value()))
          
          # Get the class of the exception
          self.emit(Instruction(kind: IkGetClass))
          
          # Load the expected exception type
          self.compile(pattern)
          
          # Check if they match (including inheritance)
          self.emit(Instruction(kind: IkIsInstance))
          
          # If not a match, jump to next catch
          self.emit(Instruction(kind: IkJumpIfFalse, arg0: next_catch_label.to_value()))

        # Catch-local scope for optional exception binding and body locals.
        self.start_scope()
        if is_symbol_binding:
          self.emit(Instruction(kind: IkPushValue, arg0: App.app.gene_ns))
          self.emit(Instruction(kind: IkGetMember, arg0: "ex".to_key().to_value()))
          if pattern.str == "_":
            self.emit(Instruction(kind: IkPop))
          else:
            let catch_var_index = self.scope_tracker.next_index
            self.scope_tracker.mappings[pattern.str.to_key()] = catch_var_index
            self.add_scope_start()
            self.scope_tracker.next_index.inc()
            self.emit(Instruction(kind: IkVar, arg0: catch_var_index.to_value()))
            self.emit(Instruction(kind: IkPop))
        elif is_destructure_binding:
          # Bind exception value through var-destructuring to keep one matcher model.
          self.emit(Instruction(kind: IkPushValue, arg0: App.app.gene_ns))
          self.emit(Instruction(kind: IkGetMember, arg0: "ex".to_key().to_value()))

          let tmp_name = ("__catch_ex_" & $catch_count & "_" & $i).to_symbol_value()
          let tmp_index = self.scope_tracker.next_index
          self.scope_tracker.mappings[tmp_name.str.to_key()] = tmp_index
          self.add_scope_start()
          self.scope_tracker.next_index.inc()
          self.emit(Instruction(kind: IkVar, arg0: tmp_index.to_value()))
          self.emit(Instruction(kind: IkPop))

          var bind_gene = new_gene("var".to_symbol_value())
          bind_gene.children.add(pattern)
          bind_gene.children.add(tmp_name)
          self.compile_var(bind_gene)
          self.emit(Instruction(kind: IkPop))
        
        # Compile catch body
        while i < gene.children.len:
          let body_child = gene.children[i]
          if body_child.kind == VkSymbol and (body_child.str == "catch" or body_child.str == "finally"):
            break
          self.compile(body_child)
          inc i

        self.end_scope()
        self.emit(Instruction(kind: IkCatchEnd))
        # Jump to finally if exists, otherwise to end
        if has_finally:
          self.emit(Instruction(kind: IkJump, arg0: finally_label.to_value()))
        else:
          self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))
        
        # Add label for next catch if this was a type-specific catch
        if not is_catch_all and not is_catch_binding:
          self.emit(Instruction(kind: IkNoop, label: next_catch_label))
          # Pop the exception handler and push it back for the next catch
          self.emit(Instruction(kind: IkCatchRestore))
        
        catch_count.inc
    elif child.kind == VkSymbol and child.str == "finally":
      break
    else:
      inc i
  
  # If no catch blocks handled the exception, re-throw
  if catch_count > 0:
    self.emit(Instruction(kind: IkThrow))
  
  # Handle finally block
  if has_finally:
    self.emit(Instruction(kind: IkNoop, label: finally_label))
    self.emit(Instruction(kind: IkFinally))
    
    # Compile finally body
    i = finally_idx + 1
    while i < gene.children.len:
      self.compile(gene.children[i])
      inc i
    
    self.emit(Instruction(kind: IkFinallyEnd))
  
  self.emit(Instruction(kind: IkNoop, label: end_label))
