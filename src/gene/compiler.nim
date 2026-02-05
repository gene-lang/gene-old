import tables, strutils, streams, os

import ./types
import ./parser
import ./type_checker
import "./compiler/if"
import "./compiler/case"

const DEBUG = false

proc container_key(): Key {.inline.} =
  "container".to_key()

proc local_def_key(): Key {.inline.} =
  "local_def".to_key()

proc binding_type_from_props(gene: ptr Gene): string =
  if gene == nil:
    return ""
  let key = TC_BINDING_TYPE_KEY.to_key()
  if gene.props.has_key(key):
    let val = gene.props[key]
    if val.kind in {VkString, VkSymbol}:
      return val.str
    return type_expr_to_string(val)
  return ""

proc set_expected_type(tracker: ScopeTracker, index: int16, expected_type: string) {.inline.} =
  if tracker == nil or expected_type.len == 0:
    return
  while tracker.type_expectations.len <= index.int:
    tracker.type_expectations.add("")
  tracker.type_expectations[index.int] = expected_type

proc build_container_value(parts: seq[string]): Value =
  if parts.len == 0:
    return NIL
  if parts.len == 1:
    return parts[0].to_symbol_value()
  parts.to_complex_symbol()

proc split_container_name(name: Value): tuple[base: Value, container: Value] =
  result.base = name
  result.container = NIL

  proc normalize_prefix(prefix: seq[string]): seq[string] =
    result = @[]
    if prefix.len == 0:
      return
    result = prefix
    if result.len > 0 and result[0].len == 0:
      result[0] = "self"

  case name.kind
  of VkComplexSymbol:
    let cs = name.ref.csymbol
    if cs.len < 2:
      return
    if cs[0] == "$ns":
      return
    let prefix = cs[0..^2]
    if prefix.len == 0:
      return
    let normalized = normalize_prefix(prefix)
    let container_value = build_container_value(normalized)
    if container_value == NIL:
      return
    result.base = cs[^1].to_symbol_value()
    result.container = container_value
  of VkSymbol:
    let s = name.str
    if s.contains("/") and s != "$ns":
      let parts = s.split("/")
      if parts.len < 2:
        return
      if parts[0] == "$ns":
        return
      var prefix = parts[0..^2]
      let normalized = normalize_prefix(prefix)
      let container_value = build_container_value(normalized)
      if container_value == NIL:
        return
      result.base = parts[^1].to_symbol_value()
      result.container = container_value
  else:
    discard

proc apply_container_to_child(gene: ptr Gene, child_index: int) =
  if gene.children.len <= child_index:
    return
  if gene.props.hasKey(container_key()):
    return
  let (base, container_value) = split_container_name(gene.children[child_index])
  if container_value == NIL:
    return
  gene.props[container_key()] = container_value
  gene.children[child_index] = base

proc apply_container_to_type(gene: ptr Gene) =
  if gene.props.hasKey(container_key()):
    return
  let (base, container_value) = split_container_name(gene.type)
  if container_value == NIL:
    return
  gene.props[container_key()] = container_value
  gene.type = base

#################### Trace Helpers #################

proc current_trace(self: Compiler): SourceTrace =
  if self.trace_stack.len == 0:
    return nil
  self.trace_stack[^1]

proc push_trace(self: Compiler, trace: SourceTrace) =
  if trace.is_nil:
    return
  self.trace_stack.add(trace)

proc pop_trace(self: Compiler) =
  if self.trace_stack.len > 0:
    self.trace_stack.setLen(self.trace_stack.len - 1)

proc emit(self: Compiler, instr: Instruction) =
  if self.output.is_nil:
    return
  self.output.add_instruction(instr, self.current_trace())

#################### Definitions #################
proc compile*(self: Compiler, input: Value)
proc compile_with(self: Compiler, gene: ptr Gene)
proc compile_tap(self: Compiler, gene: ptr Gene)
proc compile_if_main(self: Compiler, gene: ptr Gene)
proc compile_parse(self: Compiler, gene: ptr Gene)
proc compile_render(self: Compiler, gene: ptr Gene)
proc compile_emit(self: Compiler, gene: ptr Gene)
proc compile*(f: Function, eager_functions: bool)
proc compile*(b: Block, eager_functions: bool)
proc compile_caller_eval(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_async(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_await(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_spawn(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_yield(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_selector(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_at_selector(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_set(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_import(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_export(self: Compiler, gene: ptr Gene)  # Forward declaration
proc compile_init*(input: Value, local_defs = false): CompilationUnit  # Forward declaration
proc predeclare_local_defs(self: Compiler, nodes: seq[Value])  # Forward declaration

proc is_vmstmt_form(input: Value): bool =
  input.kind == VkGene and
    input.gene.`type`.kind == VkSymbol and
    input.gene.`type`.str == "$vmstmt"

proc compile_vmstmt(self: Compiler, gene: ptr Gene) =
  if gene.props.len > 0:
    not_allowed("$vmstmt does not accept properties")
  if gene.children.len != 1:
    not_allowed("$vmstmt expects exactly 1 argument")
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    not_allowed("$vmstmt builtin name must be a symbol")
  if name_val.str != "duration_start":
    not_allowed("Unknown $vmstmt builtin: " & name_val.str)
  self.emit(Instruction(kind: IkVmDurationStart))

proc compile(self: Compiler, input: seq[Value], allow_vmstmt_last = false) =
  for i, v in input:
    # Set tail position for the last expression
    let old_tail = self.tail_position
    let is_last = i == input.len - 1
    if is_last:
      # Last expression inherits current tail position
      discard
    else:
      # Non-last expressions are never in tail position
      self.tail_position = false

    if is_vmstmt_form(v):
      if is_last and not allow_vmstmt_last:
        not_allowed("$vmstmt is statement-only")
      self.compile_vmstmt(v.gene)
    else:
      self.compile(v)
      if not is_last:
        self.emit(Instruction(kind: IkPop))

    # Restore tail position
    self.tail_position = old_tail

proc compile_literal(self: Compiler, input: Value) =
  self.emit(Instruction(kind: IkPushValue, arg0: input))

proc compile_unary_not(self: Compiler, operand: Value) {.inline.} =
  ## Emit bytecode for a logical not.
  self.compile(operand)
  self.emit(Instruction(kind: IkNot))

proc compile_var_op_literal(self: Compiler, symbolVal: Value, literal: Value, opKind: InstructionKind): bool =
  ## Emit optimized instruction when a variable is operated with a literal.
  if symbolVal.kind != VkSymbol or not literal.is_literal():
    return false

  let key = symbolVal.str.to_key()
  let found = self.scope_tracker.locate(key)
  if found.local_index >= 0:
    self.emit(Instruction(
      kind: opKind,
      arg0: found.local_index.to_value(),
      arg1: found.parent_index.int32
    ))
    self.emit(Instruction(kind: IkData, arg0: literal))
    return true
  false

proc simple_def_name(name_val: Value): string =
  ## Return a simple local name for defs (fn/class/ns/etc) or "" when not eligible.
  case name_val.kind
  of VkSymbol, VkString:
    let name = name_val.str
    if name.len == 0:
      return ""
    if name.contains("/") or name.starts_with("$"):
      return ""
    return name
  else:
    return ""

proc reserve_local_binding(self: Compiler, name: string): tuple[index: int16, new_binding: bool, old_next_index: int16, key: Key] =
  let key = name.to_key()
  var declared_here = false
  if self.declared_names.len > 0:
    declared_here = self.declared_names[^1].has_key(key)

  let has_mapping = self.scope_tracker.mappings.has_key(key)
  let old_next_index = self.scope_tracker.next_index
  var index: int16
  var new_binding = false

  if has_mapping and not declared_here:
    index = self.scope_tracker.mappings[key]
  else:
    index = old_next_index
    new_binding = true
    self.scope_tracker.mappings[key] = index
    self.scope_tracker.next_index = old_next_index + 1

  result = (index, new_binding, old_next_index, key)

# Translate $x to global/x and $x/y to global/x/y
proc translate_symbol(input: Value): Value =
  case input.kind:
    of VkSymbol:
      let s = input.str
      if s.starts_with("$") and s.len > 1:
        # Special case for $ns - translate to special symbol
        if s == "$ns":
          result = cast[Value](SYM_NS)
        else:
          result = @["SPECIAL_GLOBAL", s[1..^1]].to_complex_symbol()
      else:
        result = input
    of VkComplexSymbol:
      result = input
      let r = input.ref
      if r.csymbol[0] == "":
        r.csymbol[0] = "self"
      elif r.csymbol[0] == "$ns":
        r.csymbol[0] = "SPECIAL_NS"
      elif r.csymbol[0].starts_with("$") and r.csymbol[0].len > 1:
        let stripped = r.csymbol[0][1..^1]
        r.csymbol[0] = "SPECIAL_GLOBAL"
        r.csymbol.insert(stripped, 1)
    else:
      not_allowed($input)

proc compile_complex_symbol(self: Compiler, input: Value) =
  if self.quote_level > 0:
    self.emit(Instruction(kind: IkPushValue, arg0: input))
  else:
    let r = translate_symbol(input).ref
    if r.csymbol.len > 0 and r.csymbol[0].startsWith("@"):
      var segments: seq[Value] = @[]

      proc add_segment(part: string) =
        if part.len == 0:
          not_allowed("@ selector segment cannot be empty")
        if part == "!":
          # Special path operator: assert not void (used by @a/!/b and @a/b/!)
          segments.add("!".to_symbol_value())
          return
        try:
          let index = parseInt(part)
          segments.add(index.to_value())
        except ValueError:
          segments.add(part.to_value())

      add_segment(r.csymbol[0][1..^1])
      for part in r.csymbol[1..^1]:
        add_segment(part)

      if segments.len == 0:
        not_allowed("@ selector requires at least one segment")

      let selector_value = new_selector_value(segments)
      self.emit(Instruction(kind: IkPushValue, arg0: selector_value))
      return

    let key = r.csymbol[0].to_key()
    if r.csymbol[0] == "SPECIAL_GLOBAL":
      # Handle $x/... by resolving against the global namespace.
      self.emit(Instruction(kind: IkPushValue, arg0: App.app.global_ns))
    elif r.csymbol[0] == "SPECIAL_NS":
      # Handle $ns/... specially
      self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](SYM_NS)))
    else:
      # Use locate to check parent scopes too
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
    for s in r.csymbol[1..^1]:
      if s == "!":
        self.emit(Instruction(kind: IkAssertNotVoid))
        continue
      let (is_int, i) = to_int(s)
      if is_int:
        self.emit(Instruction(kind: IkPushValue, arg0: i.to_value()))
        self.emit(Instruction(kind: IkGetMemberOrNil))
      elif s.starts_with("."):
        let method_value = s[1..^1].to_symbol_value()
        if self.method_access_mode == MamReference:
          # Preserve legacy behavior when compiling method references
          self.emit(Instruction(kind: IkResolveMethod, arg0: method_value))
        else:
          # Default: immediately invoke zero-arg method via dot notation
          self.emit(Instruction(kind: IkUnifiedMethodCall0, arg0: method_value))
      elif s == "...":
        # Spread operator in complex symbols - not yet implemented
        # This would handle cases like a/.../b but is an edge case
        # For now, just treat it as a regular member access
        not_allowed("Spread operator (...) in complex symbols not supported")
      else:
        self.emit(Instruction(kind: IkPushValue, arg0: s.to_symbol_value()))
        self.emit(Instruction(kind: IkGetMemberOrNil))

proc compile_symbol(self: Compiler, input: Value) =
  if self.quote_level > 0:
    self.emit(Instruction(kind: IkPushValue, arg0: input))
  else:
    let input = translate_symbol(input)
    if input.kind == VkSymbol:
      let symbol_str = input.str
      if symbol_str == "self":
        # Check if self is a local variable (in methods compiled as functions)
        let key = symbol_str.to_key()
        let found = self.scope_tracker.locate(key)
        if found.local_index >= 0:
          # self is a parameter - resolve it as a variable
          if found.parent_index == 0:
            self.emit(Instruction(kind: IkVarResolve, arg0: found.local_index.to_value()))
          else:
            self.emit(Instruction(kind: IkVarResolveInherited, arg0: found.local_index.to_value(), arg1: found.parent_index))
        else:
          # Fall back to IkSelf for non-method contexts
          self.emit(Instruction(kind: IkSelf))
        return
      elif symbol_str == "super":
        # Push runtime super proxy (handled by IkSuper at execution time)
        self.emit(Instruction(kind: IkSuper))
        return
      elif symbol_str.startsWith("@") and symbol_str.len > 1:
        # Handle @shorthand syntax: @test -> (@ "test"), @0 -> (@ 0)
        let prop_name = symbol_str[1..^1]

        var segments: seq[Value] = @[]
        for part in prop_name.split("/"):
          if part.len == 0:
            not_allowed("@ selector segment cannot be empty")
          if part == "!":
            segments.add("!".to_symbol_value())
            continue
          try:
            let index = parseInt(part)
            segments.add(index.to_value())
          except ValueError:
            segments.add(part.to_value())

        if segments.len == 0:
          not_allowed("@ selector requires at least one segment")

        let selector_value = new_selector_value(segments)
        self.emit(Instruction(kind: IkPushValue, arg0: selector_value))
        return
      elif symbol_str.endsWith("..."):
        # Spread suffix like "a..." - this should be handled by compile_array/compile_gene
        # If we get here, it's being used outside of those contexts which is an error
        not_allowed("Spread operator (...) can only be used in arrays, maps, or gene expressions")
      let key = input.str.to_key()
      let found = self.scope_tracker.locate(key)
      if found.local_index >= 0:
        if found.parent_index == 0:
          self.emit(Instruction(kind: IkVarResolve, arg0: found.local_index.to_value()))
        else:
          self.emit(Instruction(kind: IkVarResolveInherited, arg0: found.local_index.to_value(), arg1: found.parent_index))
      else:
        self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](key)))
    elif input.kind == VkComplexSymbol:
      self.compile_complex_symbol(input)

proc compile_array(self: Compiler, input: Value) =
  # Use call base approach: push base, compile elements onto stack, collect at end
  self.emit(Instruction(kind: IkArrayStart))

  var i = 0
  let arr = array_data(input)
  while i < arr.len:
    let child = arr[i]

    # Check for standalone postfix spread: expr ...
    if i + 1 < arr.len and arr[i + 1].kind == VkSymbol and arr[i + 1].str == "...":
      # Compile the expression and spread its elements
      self.compile(child)
      self.emit(Instruction(kind: IkArrayAddSpread))
      i += 2  # Skip both the expr and the ... symbol
      continue

    # Check for suffix spread: a...
    if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
      # Compile the base symbol and spread its elements
      let base_symbol = child.str[0..^4].to_symbol_value()  # Remove "..."
      self.compile(base_symbol)
      self.emit(Instruction(kind: IkArrayAddSpread))
      i += 1
      continue

    # Normal element - just compile it (pushes to stack)
    self.compile(child)
    i += 1

  # Collect all elements from call base into array
  self.emit(Instruction(kind: IkArrayEnd))

proc compile_stream(self: Compiler, input: Value, allow_vmstmt_last = false) =
  # For simple streams (used by if/elif/else branches), just compile the children directly
  # Don't emit StreamStart/StreamEnd as they're not needed for control flow
  let stream_values = input.ref.stream

  if stream_values.len == 0:
    self.emit(Instruction(kind: IkPushValue, arg0: NIL))
    return

  var i = 0
  while i < stream_values.len:
    let child = stream_values[i]
    let old_tail = self.tail_position
    let is_last = i == stream_values.len - 1
    if is_last:
      # Last expression preserves tail position
      discard
    else:
      self.tail_position = false

    if is_vmstmt_form(child):
      if is_last and not allow_vmstmt_last:
        not_allowed("$vmstmt is statement-only")
      self.compile_vmstmt(child.gene)
    else:
      self.compile(child)

    self.tail_position = old_tail
    if i < stream_values.len - 1 and not is_vmstmt_form(child):
      self.emit(Instruction(kind: IkPop))

    i += 1

proc compile_map(self: Compiler, input: Value) =
  self.emit(Instruction(kind: IkMapStart))
  for k, v in map_data(input):
    let key_str = $k
    # Check for spread key: ^..., ^...1, ^...2, etc.
    if key_str.startsWith("..."):
      # Spread map into current map
      self.compile(v)
      self.emit(Instruction(kind: IkMapSpread))
    else:
      # Normal key-value pair
      self.compile(v)
      self.emit(Instruction(kind: IkMapSetProp, arg0: k))
  self.emit(Instruction(kind: IkMapEnd))

# Forward declarations for scope helpers used below
proc start_scope(self: Compiler)
proc add_scope_start(self: Compiler)
proc end_scope(self: Compiler)

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

proc compile_var(self: Compiler, gene: ptr Gene) =
  if gene.children.len == 0:
    not_allowed("var requires a name")
  apply_container_to_child(gene, 0)
  let container_expr = gene.props.getOrDefault(container_key(), NIL)
  var explicit_type = ""
  # Strip optional type annotation: (var x: Type value)
  if gene.children.len >= 2:
    let name_val = gene.children[0]
    if name_val.kind == VkSymbol and name_val.str.ends_with(":"):
      let base_name = name_val.str[0..^2].to_symbol_value()
      if gene.children.len > 1:
        explicit_type = type_expr_to_string(gene.children[1])
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

  var binding_type = binding_type_from_props(gene)
  if binding_type.len == 0:
    binding_type = explicit_type

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
    set_expected_type(self.scope_tracker, index, binding_type)
    self.emit(Instruction(kind: IkVar, arg0: index.to_value()))
  else:
    if new_binding:
      self.scope_tracker.mappings[key] = index
      self.scope_tracker.next_index = old_next_index + 1
    self.add_scope_start()
    set_expected_type(self.scope_tracker, index, binding_type)
    self.emit(Instruction(kind: IkVarValue, arg0: NIL, arg1: index))

  if not new_binding:
    self.scope_tracker.next_index = old_next_index

  if self.declared_names.len > 0:
    self.declared_names[^1][key] = true

proc compile_container_assignment(self: Compiler, container_expr: Value, name_sym: Value, operator: string, rhs: Value) =
  if name_sym.kind != VkSymbol:
    not_allowed("Container assignment target must resolve to a symbol")
  let name_str = name_sym.str
  let (is_index, index) = to_int(name_str)
  self.compile(container_expr)
  if operator != "=":
    self.emit(Instruction(kind: IkDup))
    if is_index:
      self.emit(Instruction(kind: IkGetChild, arg0: index))
    else:
      self.emit(Instruction(kind: IkGetMember, arg0: name_sym))
  self.compile(rhs)
  case operator:
    of "=":
      discard
    of "+=":
      self.emit(Instruction(kind: IkAdd))
    of "-=":
      self.emit(Instruction(kind: IkSub))
    else:
      not_allowed("Unsupported compound assignment operator: " & operator)
  if is_index:
    self.emit(Instruction(kind: IkSetChild, arg0: index))
  else:
    self.emit(Instruction(kind: IkSetMember, arg0: name_sym))

proc compile_assignment(self: Compiler, gene: ptr Gene) =
  apply_container_to_type(gene)
  let `type` = gene.type
  let operator = gene.children[0].str
  let container_expr = gene.props.getOrDefault(container_key(), NIL)
  
  if `type`.kind == VkSymbol:
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
    
    # Load the target object first (for both regular and compound assignment)
    if r.csymbol[0] == "SPECIAL_NS":
      self.emit(Instruction(kind: IkResolveSymbol, arg0: cast[Value](SYM_NS)))
    elif self.scope_tracker.mappings.has_key(key):
      self.emit(Instruction(kind: IkVarResolve, arg0: self.scope_tracker.mappings[key].to_value()))
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
      let last_segment = r.csymbol[^1]
      let (is_int, i) = to_int(last_segment)
      if is_int:
        self.emit(Instruction(kind: IkGetChild, arg0: i))
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
        else:
          not_allowed("Unsupported compound assignment operator: " & operator)
      
      # Now stack should be: [target, new_value]
      # Set the property
      let last_segment2 = r.csymbol[^1]
      let (is_int2, i2) = to_int(last_segment2)
      if is_int2:
        self.emit(Instruction(kind: IkSetChild, arg0: i2))
      else:
        self.emit(Instruction(kind: IkSetMember, arg0: last_segment2.to_key()))
    else:
      # Regular assignment
      self.compile(gene.children[1])
      
      let last_segment = r.csymbol[^1]
      let (is_int, i) = to_int(last_segment)
      if is_int:
        self.emit(Instruction(kind: IkSetChild, arg0: i))
      else:
        self.emit(Instruction(kind: IkSetMember, arg0: last_segment.to_key()))
  else:
    not_allowed($`type`)

proc compile_loop(self: Compiler, gene: ptr Gene) =
  let start_label = new_label()
  let end_label = new_label()
  
  # Track this loop
  self.loop_stack.add(LoopInfo(start_label: start_label, end_label: end_label, scope_depth: self.started_scope_depth))
  
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
  self.loop_stack.add(LoopInfo(start_label: label, end_label: end_label, scope_depth: self.started_scope_depth))
  
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
  self.loop_stack.add(LoopInfo(start_label: start_label, end_label: end_label, scope_depth: self.started_scope_depth))

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
  # (for var in collection body...)
  if gene.children.len < 2:
    not_allowed("for expects at least 2 arguments (variable and collection)")
  
  let var_node = gene.children[0]
  var index_name: string = ""
  var value_name: string = ""
  case var_node.kind
  of VkSymbol:
    value_name = var_node.str
  of VkArray:
    let items = array_data(var_node)
    if items.len != 2 or items[0].kind != VkSymbol or items[1].kind != VkSymbol:
      not_allowed("for loop variable must be a symbol or [index value]")
    index_name = items[0].str
    value_name = items[1].str
  else:
    not_allowed("for loop variable must be a symbol or [index value]")
  
  # Check for 'in' keyword
  if gene.children.len < 3 or gene.children[1].kind != VkSymbol or gene.children[1].str != "in":
    not_allowed("for loop requires 'in' keyword")
  
  let var_name = value_name
  let collection = gene.children[2]
  
  # Create a scope for the entire for loop to hold temporary variables
  self.start_scope()
  
  # Store collection in a temporary variable
  self.compile(collection)
  let collection_index = self.scope_tracker.next_index
  self.scope_tracker.mappings["$for_collection".to_key()] = collection_index
  self.add_scope_start()
  self.scope_tracker.next_index.inc()
  self.emit(Instruction(kind: IkVar, arg0: collection_index.to_value()))
  # Drop the pushed collection value; we only need it in scope
  self.emit(Instruction(kind: IkPop))
  
  # Store index in a temporary variable, initialized to 0
  self.emit(Instruction(kind: IkPushValue, arg0: 0.to_value()))
  let index_var = self.scope_tracker.next_index
  self.scope_tracker.mappings["$for_index".to_key()] = index_var
  self.scope_tracker.next_index.inc()
  self.emit(Instruction(kind: IkVar, arg0: index_var.to_value()))
  # Drop the pushed index initial value
  self.emit(Instruction(kind: IkPop))
  
  let start_label = new_label()
  let end_label = new_label()
  
  # Track this loop
  self.loop_stack.add(LoopInfo(start_label: start_label, end_label: end_label, scope_depth: self.started_scope_depth))
  
  # Mark loop start
  self.emit(Instruction(kind: IkLoopStart, label: start_label))
  
  # Check if index < collection.length
  # Load index
  self.emit(Instruction(kind: IkVarResolve, arg0: index_var.to_value()))
  # Load collection
  self.emit(Instruction(kind: IkVarResolve, arg0: collection_index.to_value()))
  # Get length
  self.emit(Instruction(kind: IkLen))
  # Compare
  self.emit(Instruction(kind: IkLt))
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: end_label.to_value()))
  
  # Create scope for loop iteration
  self.start_scope()
  
  # Get current element: collection[index]
  # Load collection
  self.emit(Instruction(kind: IkVarResolve, arg0: collection_index.to_value()))
  # Load index
  self.emit(Instruction(kind: IkVarResolve, arg0: index_var.to_value()))
  # Get element
  self.emit(Instruction(kind: IkGetChildDynamic))
  
  # Store index in loop variable if requested
  if index_name.len > 0 and index_name != "_":
    self.emit(Instruction(kind: IkVarResolve, arg0: index_var.to_value()))
    let idx_var = self.scope_tracker.next_index
    self.scope_tracker.mappings[index_name.to_key()] = idx_var
    self.add_scope_start()
    self.scope_tracker.next_index.inc()
    self.emit(Instruction(kind: IkVar, arg0: idx_var.to_value()))
    self.emit(Instruction(kind: IkPop))

  # Store element in loop variable
  if var_name != "_":
    let var_index = self.scope_tracker.next_index
    self.scope_tracker.mappings[var_name.to_key()] = var_index
    self.add_scope_start()
    self.scope_tracker.next_index.inc()
    self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
    # Remove the element value that IkVar leaves on the stack
    self.emit(Instruction(kind: IkPop))
  else:
    # Drop the element when the value is ignored
    self.emit(Instruction(kind: IkPop))
  
  # Compile body (remaining children after 'in' and collection)
  if gene.children.len > 3:
    for i in 3..<gene.children.len:
      let child = gene.children[i]
      if is_vmstmt_form(child):
        self.compile_vmstmt(child.gene)
      else:
        self.compile(child)
        # Pop the result (we don't need it)
        self.emit(Instruction(kind: IkPop))
  
  # End the iteration scope
  self.end_scope()
  
  # Increment index
  # Load current index
  self.emit(Instruction(kind: IkVarResolve, arg0: index_var.to_value()))
  # Add 1
  self.emit(Instruction(kind: IkPushValue, arg0: 1.to_value()))
  self.emit(Instruction(kind: IkAdd))
  # Store back
  self.emit(Instruction(kind: IkVarAssign, arg0: index_var.to_value()))
  
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

proc compile_enum(self: Compiler, gene: ptr Gene) =
  # (enum Color red green blue)
  # (enum Status ^values [ok error pending])
  if gene.children.len < 1:
    not_allowed("enum expects at least a name")
  
  let name_node = gene.children[0]
  if name_node.kind != VkSymbol:
    not_allowed("enum name must be a symbol")
  
  let enum_name = name_node.str
  
  # Create the enum
  self.emit(Instruction(kind: IkPushValue, arg0: enum_name.to_value()))
  self.emit(Instruction(kind: IkCreateEnum))
  
  # Check if ^values prop is used
  var start_idx = 1
  if gene.props.has_key("values".to_key()):
    # Values are provided in the ^values property
    let values_array = gene.props["values".to_key()]
    if values_array.kind != VkArray:
      not_allowed("enum ^values must be an array")
    
    var value = 0
    for member in array_data(values_array):
      if member.kind != VkSymbol:
        not_allowed("enum member must be a symbol")
      # Push member name and value
      self.emit(Instruction(kind: IkPushValue, arg0: member.str.to_value()))
      self.emit(Instruction(kind: IkPushValue, arg0: value.to_value()))
      self.emit(Instruction(kind: IkEnumAddMember))
      value.inc()
  else:
    # Members are provided as children
    var value = 0
    var i = start_idx
    while i < gene.children.len:
      let member = gene.children[i]
      if member.kind != VkSymbol:
        not_allowed("enum member must be a symbol")
      
      # Check if next child is '=' for custom value
      if i + 2 < gene.children.len and 
         gene.children[i + 1].kind == VkSymbol and 
         gene.children[i + 1].str == "=":
        # Custom value provided
        i += 2
        if gene.children[i].kind != VkInt:
          not_allowed("enum member value must be an integer")
        value = gene.children[i].int64.int
      
      # Push member name and value
      self.emit(Instruction(kind: IkPushValue, arg0: member.str.to_value()))
      self.emit(Instruction(kind: IkPushValue, arg0: value.to_value()))
      self.emit(Instruction(kind: IkEnumAddMember))
      
      value.inc()
      i.inc()
  
  # Store the enum in the namespace  
  let index = self.scope_tracker.next_index
  self.scope_tracker.mappings[enum_name.to_key()] = index
  self.add_scope_start()
  self.scope_tracker.next_index.inc()
  self.emit(Instruction(kind: IkVar, arg0: index.to_value()))

proc compile_break(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    self.compile(gene.children[0])
  else:
    self.emit(Instruction(kind: IkPushNil))
  
  if self.loop_stack.len == 0:
    # Emit a break with label -1 to indicate no loop
    # This will be checked at runtime
    self.emit(Instruction(kind: IkBreak, arg0: (-1).to_value()))
  else:
    let current_loop = self.loop_stack[^1]
    let unwind_count = self.started_scope_depth.int - current_loop.scope_depth.int
    if unwind_count > 0:
      for _ in 0..<unwind_count:
        self.emit(Instruction(kind: IkScopeEnd))
    # Get the current loop's end label
    self.emit(Instruction(kind: IkBreak, arg0: current_loop.end_label.to_value()))

proc compile_continue(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    self.compile(gene.children[0])
  else:
    self.emit(Instruction(kind: IkPushNil))
  
  if self.loop_stack.len == 0:
    # Emit a continue with label -1 to indicate no loop
    # This will be checked at runtime
    self.emit(Instruction(kind: IkContinue, arg0: (-1).to_value()))
  else:
    let current_loop = self.loop_stack[^1]
    let unwind_count = self.started_scope_depth.int - current_loop.scope_depth.int
    if unwind_count > 0:
      for _ in 0..<unwind_count:
        self.emit(Instruction(kind: IkScopeEnd))
    # Get the current loop's start label
    self.emit(Instruction(kind: IkContinue, arg0: current_loop.start_label.to_value()))

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
        let is_catch_all = pattern.kind == VkSymbol and pattern.str == "*"
        
        # Generate catch matching code
        if is_catch_all:
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
        
        # Compile catch body
        while i < gene.children.len:
          let body_child = gene.children[i]
          if body_child.kind == VkSymbol and (body_child.str == "catch" or body_child.str == "finally"):
            break
          self.compile(body_child)
          inc i
        
        self.emit(Instruction(kind: IkCatchEnd))
        # Jump to finally if exists, otherwise to end
        if has_finally:
          self.emit(Instruction(kind: IkJump, arg0: finally_label.to_value()))
        else:
          self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))
        
        # Add label for next catch if this was a type-specific catch
        if not is_catch_all:
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

proc mark_local_fn(input: Value) =
  if input.kind == VkGene and input.gene != nil:
    input.gene.props[local_def_key()] = TRUE

proc compile_fn(self: Compiler, input: Value, define_binding = true) =
  if input.kind == VkGene and input.gene != nil and input.gene.type == "fn".to_symbol_value():
    if input.gene.children.len == 0:
      not_allowed("fn requires a name or argument list")
    let first = input.gene.children[0]
    if first.kind == VkArray:
      discard
    elif first.kind in {VkSymbol, VkString, VkComplexSymbol}:
      if input.gene.children.len < 2:
        not_allowed("fn requires an argument list after the name")
      let args = input.gene.children[1]
      if args.kind != VkArray:
        not_allowed("fn argument list must be an array, e.g. [a b]")
    else:
      not_allowed("fn requires a name or argument list")

  var local_binding = false
  var local_index: int16
  var local_key: Key
  var local_new_binding = false
  var local_old_next: int16

  var should_define = define_binding
  if input.kind == VkGene and input.gene != nil:
    let first = input.gene.children[0]
    case first.kind
    of VkArray:
      should_define = false
    of VkSymbol, VkString:
      let name = first.str
      if should_define and self.local_definitions and name != "__init__":
        let simple_name = simple_def_name(first)
        if simple_name.len > 0:
          local_binding = true
          should_define = false
          let reserved = self.reserve_local_binding(simple_name)
          local_index = reserved.index
          local_new_binding = reserved.new_binding
          local_old_next = reserved.old_next_index
          local_key = reserved.key
    of VkComplexSymbol:
      discard
    else:
      discard

  if not should_define:
    mark_local_fn(input)

  let tracker_copy = copy_scope_tracker(self.scope_tracker)
  let binding_type = if input.kind == VkGene and input.gene != nil: binding_type_from_props(input.gene) else: ""

  var compiled_body: CompilationUnit = nil
  if self.eager_functions:
    var fn_obj = to_function(input)
    fn_obj.scope_tracker = tracker_copy
    compile(fn_obj, true)
    compiled_body = fn_obj.body_compiled

  let info = new_function_def_info(tracker_copy, compiled_body, input)
  self.emit(Instruction(kind: IkFunction, arg0: info.to_value()))

  if local_binding:
    self.add_scope_start()
    set_expected_type(self.scope_tracker, local_index, binding_type)
    self.emit(Instruction(kind: IkVar, arg0: local_index.to_value()))
    if not local_new_binding:
      self.scope_tracker.next_index = local_old_next
    if self.declared_names.len > 0:
      self.declared_names[^1][local_key] = true

proc compile_return(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    self.compile(gene.children[0])
  else:
    self.emit(Instruction(kind: IkPushNil))
  self.emit(Instruction(kind: IkReturn))

proc compile_block(self: Compiler, input: Value) =
  let info = new_function_def_info(self.scope_tracker, nil, input)
  self.emit(Instruction(kind: IkBlock, arg0: info.to_value()))

proc compile_ns(self: Compiler, gene: ptr Gene) =
  # Apply container splitting to handle complex symbols like app/models
  apply_container_to_child(gene, 0)
  let container_expr = gene.props.getOrDefault(container_key(), NIL)
  let container_flag = (if container_expr != NIL: 1.int32 else: 0.int32)

  var local_def = false
  var local_index: int16
  var local_key: Key
  var local_new_binding = false
  var local_old_next: int16
  if self.local_definitions and container_expr == NIL:
    let simple_name = simple_def_name(gene.children[0])
    if simple_name.len > 0:
      local_def = true
      let reserved = self.reserve_local_binding(simple_name)
      local_index = reserved.index
      local_key = reserved.key
      local_new_binding = reserved.new_binding
      local_old_next = reserved.old_next_index

  # If we have a container, compile it first to push it onto the stack
  if container_expr != NIL:
    self.compile(container_expr)

  # Emit namespace instruction with container flag
  let flags = container_flag or (if local_def: 2.int32 else: 0.int32)
  self.emit(Instruction(kind: IkNamespace, arg0: gene.children[0], arg1: flags))

  if local_def:
    self.add_scope_start()
    self.emit(Instruction(kind: IkVar, arg0: local_index.to_value()))
    if not local_new_binding:
      self.scope_tracker.next_index = local_old_next
    if self.declared_names.len > 0:
      self.declared_names[^1][local_key] = true

  # Handle namespace body if present
  if gene.children.len > 1:
    let body = new_stream_value(gene.children[1..^1])
    let compiled = compile_init(body, local_defs = true)
    let r = new_ref(VkCompiledUnit)
    r.cu = compiled
    self.emit(Instruction(kind: IkPushValue, arg0: r.to_ref_value()))
    self.emit(Instruction(kind: IkCallInit))

proc compile_method_definition(self: Compiler, gene: ptr Gene) =
  # Method definition: (method name args body...) or (method name arg body...)
  if gene.children.len < 2:
    not_allowed("Method definition requires at least name and args")
  
  let name = gene.children[0]
  if name.kind != VkSymbol:
    not_allowed("Method name must be a symbol")
  
  # Create a function from the method definition
  # The method is similar to (fn name [args] body...) but bound to the class
  var fn_value = new_gene_value()
  fn_value.gene.type = "fn".to_symbol_value()
  let param_key = TC_PARAM_TYPES_KEY.to_key()
  let return_key = TC_RETURN_TYPE_KEY.to_key()
  let effects_key = TC_EFFECTS_KEY.to_key()
  if gene.props.has_key(param_key):
    fn_value.gene.props[param_key] = gene.props[param_key]
  if gene.props.has_key(return_key):
    fn_value.gene.props[return_key] = gene.props[return_key]
  if gene.props.has_key(effects_key):
    fn_value.gene.props[effects_key] = gene.props[effects_key]
  
  # Add the method name
  fn_value.gene.children.add(gene.children[0])
  
  # Handle args - check if self is already the first parameter
  let args = gene.children[1]
  var method_args: Value
  
  if args.kind == VkArray:
    let src = array_data(args)
    if src.len == 0:
      method_args = new_array_value()
      array_data(method_args).add("self".to_symbol_value())
    elif src[0].kind == VkSymbol and src[0].str == "self":
      method_args = new_array_value()
      for arg in src:
        array_data(method_args).add(arg)
    else:
      method_args = new_array_value()
      array_data(method_args).add("self".to_symbol_value())
      for arg in src:
        array_data(method_args).add(arg)
  elif args.kind == VkSymbol and args.str == "_":
    # _ means no arguments, but methods need self
    method_args = new_array_value()
    array_data(method_args).add("self".to_symbol_value())
  elif args.kind == VkSymbol and args.str == "self":
    # Just self
    method_args = new_array_value()
    array_data(method_args).add(args)
  else:
    # Single argument that's not self - add self first
    method_args = new_array_value()
    array_data(method_args).add("self".to_symbol_value())
    array_data(method_args).add(args)
  
  fn_value.gene.children.add(method_args)

  # Add the body
  if gene.children.len == 2:
    # No body provided - default to nil
    fn_value.gene.children.add(NIL)
  else:
    for i in 2..<gene.children.len:
      fn_value.gene.children.add(gene.children[i])
  
  # Compile the function definition
  self.compile_fn(fn_value, define_binding = false)
  
  # Add the method to the class
  self.emit(Instruction(kind: IkDefineMethod, arg0: name))

proc compile_constructor_definition(self: Compiler, gene: ptr Gene) =
  # Constructor definition: (ctor args body...) or (ctor! args body...)

  # Create a function from the constructor definition
  # The constructor is similar to (fn new [args] body...) but bound to the class
  var fn_value = new_gene_value()
  fn_value.gene.type = "fn".to_symbol_value()
  let param_key = TC_PARAM_TYPES_KEY.to_key()
  let return_key = TC_RETURN_TYPE_KEY.to_key()
  let effects_key = TC_EFFECTS_KEY.to_key()
  if gene.props.has_key(param_key):
    fn_value.gene.props[param_key] = gene.props[param_key]
  if gene.props.has_key(return_key):
    fn_value.gene.props[return_key] = gene.props[return_key]
  if gene.props.has_key(effects_key):
    fn_value.gene.props[effects_key] = gene.props[effects_key]
  fn_value.gene.children.add(gene.type.str.to_symbol_value())
  
  # Handle args - always normalize to an array
  let args = gene.children[0]
  var args_array: Value
  if args.kind == VkArray:
    args_array = args
  elif args.kind == VkSymbol and args.str == "_":
    # _ means no arguments
    args_array = new_array_value()
  else:
    # Single argument without brackets - wrap it in an array
    args_array = new_array_value()
    array_data(args_array).add(args)
  fn_value.gene.children.add(args_array)
  
  # Add remaining body
  if gene.children.len == 1:
    fn_value.gene.children.add(NIL)
  else:
    for i in 1..<gene.children.len:
      fn_value.gene.children.add(gene.children[i])
  
  # Compile the function definition
  self.compile_fn(fn_value, define_binding = false)
  
  # Set as constructor for the class
  self.emit(Instruction(kind: IkDefineConstructor))

proc compile_class_with_container(self: Compiler, class_name: Value, parent_class: Value, container_expr: Value, body_start: int, gene: ptr Gene) =
  ## Helper to compile class with container handling
  ## Implements stack-based approach: compile container → push to stack → create class as member
  let has_container = container_expr != NIL
  let container_flag = (if has_container: 1.int32 else: 0.int32)

  var local_def = false
  var local_index: int16
  var local_key: Key
  var local_new_binding = false
  var local_old_next: int16
  if self.local_definitions and not has_container:
    let simple_name = simple_def_name(class_name)
    if simple_name.len > 0:
      local_def = true
      let reserved = self.reserve_local_binding(simple_name)
      local_index = reserved.index
      local_key = reserved.key
      local_new_binding = reserved.new_binding
      local_old_next = reserved.old_next_index

  # If we have a container, compile it first to push it onto the stack
  if has_container:
    self.compile(container_expr)

  # Emit class or subclass instruction
  let flags = container_flag or (if local_def: 2.int32 else: 0.int32)
  if parent_class != NIL:
    self.compile(parent_class)
    self.emit(Instruction(kind: IkSubClass, arg0: class_name, arg1: flags))
  else:
    self.emit(Instruction(kind: IkClass, arg0: class_name, arg1: flags))

  if local_def:
    self.add_scope_start()
    self.emit(Instruction(kind: IkVar, arg0: local_index.to_value()))
    if not local_new_binding:
      self.scope_tracker.next_index = local_old_next
    if self.declared_names.len > 0:
      self.declared_names[^1][local_key] = true

  # Compile class body if present
  if gene.children.len > body_start:
    let body = new_stream_value(gene.children[body_start..^1])
    let compiled = compile_init(body, local_defs = true)
    let r = new_ref(VkCompiledUnit)
    r.cu = compiled
    self.emit(Instruction(kind: IkPushValue, arg0: r.to_ref_value()))
    self.emit(Instruction(kind: IkCallInit))

proc compile_class(self: Compiler, gene: ptr Gene) =
  apply_container_to_child(gene, 0)
  let container_expr = gene.props.getOrDefault(container_key(), NIL)

  var body_start = 1
  var parent_class: Value = NIL

  # Check for inheritance syntax: (class Name < Parent ...)
  if gene.children.len >= 3 and gene.children[1] == "<".to_symbol_value():
    body_start = 3
    parent_class = gene.children[2]

  # Use helper function for actual compilation
  self.compile_class_with_container(gene.children[0], parent_class, container_expr, body_start, gene)

proc compile_object(self: Compiler, gene: ptr Gene) =
  if gene.children.len == 0:
    not_allowed("object requires a name")

  apply_container_to_child(gene, 0)
  let container_expr = gene.props.getOrDefault(container_key(), NIL)
  let name = gene.children[0]

  if name.kind != VkSymbol:
    not_allowed("object name must be a symbol")

  var class_name_str = name.str
  if class_name_str.len == 0:
    not_allowed("object name cannot be empty")
  if not class_name_str.ends_with("Class"):
    class_name_str &= "Class"
  let class_name = class_name_str.to_symbol_value()

  # Build class definition gene
  let inherits_symbol = "<".to_symbol_value()
  var class_gene = new_gene("class".to_symbol_value())
  if container_expr != NIL:
    class_gene.props[container_key()] = container_expr
  class_gene.children.add(class_name)

  var body_start = 1
  if gene.children.len >= 3 and gene.children[1] == inherits_symbol:
    class_gene.children.add(inherits_symbol)
    class_gene.children.add(gene.children[2])
    body_start = 3

  for i in body_start..<gene.children.len:
    class_gene.children.add(gene.children[i])

  self.compile(class_gene.to_gene_value())

  # Instantiate singleton and bind it to the provided name
  var new_call = new_gene("new".to_symbol_value())
  new_call.children.add(class_name)

  var var_gene = new_gene("var".to_symbol_value())
  if container_expr != NIL:
    var_gene.props[container_key()] = container_expr
  var_gene.children.add(name)
  var_gene.children.add(new_call.to_gene_value())
  self.compile(var_gene.to_gene_value())

  # Return the singleton instance so (object ...) can be used as an expression
  self.compile(name)

# Construct a Gene object whose type is the class
# The Gene object will be used as the arguments to the constructor
proc compile_new(self: Compiler, gene: ptr Gene) =
  if gene.children.len < 1:
    raise new_exception(types.Exception, "new requires at least a class name")

  # Check if this is a macro constructor call (new!)
  let is_macro_new = gene.type.kind == VkSymbol and gene.type.str == "new!"

# Compile the class first, then the arguments
  # Stack will be: [class, args] so VM can pop args first, then class
  self.compile(gene.children[0])

  # Always create a Gene for arguments (for both regular and macro constructors)
  # This ensures the VM validation logic works correctly
  if gene.children.len > 1 or gene.props.len > 0:
    # Create a Gene containing all arguments
    self.emit(Instruction(kind: IkGeneStart))

    if is_macro_new:
      # For macro constructor, don't evaluate arguments - pass them as quoted
      self.quote_level.inc()
      for k, v in gene.props:
        let key_str = $k
        if key_str.startsWith("..."):
          self.compile(v)
          self.emit(Instruction(kind: IkGenePropsSpread))
        else:
          self.compile(v)
          self.emit(Instruction(kind: IkGeneSetProp, arg0: k))
      for i in 1..<gene.children.len:
        self.compile(gene.children[i])
        self.emit(Instruction(kind: IkGeneAddChild))
      self.quote_level.dec()
    else:
      # For regular constructor, evaluate arguments normally, then add to Gene
      for k, v in gene.props:
        let key_str = $k
        if key_str.startsWith("..."):
          self.compile(v)
          self.emit(Instruction(kind: IkGenePropsSpread))
        else:
          self.compile(v)
          self.emit(Instruction(kind: IkGeneSetProp, arg0: k))
      for i in 1..<gene.children.len:
        self.compile(gene.children[i])
        self.emit(Instruction(kind: IkGeneAddChild))

    self.emit(Instruction(kind: IkGeneEnd))
  else:
    # No arguments - push empty Gene
    self.emit(Instruction(kind: IkGeneStart))
    self.emit(Instruction(kind: IkGeneEnd))

  # Use unified IkNew instruction for both regular and macro constructors
  # Runtime validation will handle the differences
  self.emit(Instruction(kind: IkNew, arg1: is_macro_new.int32))

proc compile_super(self: Compiler, gene: ptr Gene) =
  # Super: returns the parent class
  # Usage: (super .method args...)
  if gene.children.len > 0:
    not_allowed("super takes no arguments")
  
  # Push the parent class
  self.emit(Instruction(kind: IkSuper))

proc compile_match(self: Compiler, gene: ptr Gene) =
  # Match statement: (match pattern value)
  if gene.children.len != 2:
    not_allowed("match expects exactly 2 arguments: pattern and value")

  let pattern = gene.children[0]
  let value = gene.children[1]

  # Compile the value expression
  self.compile(value)

  # Ensure we have an active scope for pattern matching
  if self.scope_trackers.len == 0:
    not_allowed("match must be used within a scope")

  # For now, handle simple variable binding: (match a [1])
  if pattern.kind == VkSymbol:
    # Simple variable binding
    let var_name = pattern.str

    let var_index = self.scope_tracker.next_index
    self.scope_tracker.mappings[var_name.to_key()] = var_index
    self.add_scope_start()
    self.scope_tracker.next_index.inc()

    # Store the value in the variable
    self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))

    # Push nil as the result of match
    self.emit(Instruction(kind: IkPushNil))

  elif pattern.kind == VkArray:
    # Array pattern matching: (match [a b] [1 2])
    # Stack has the array value on top

    for i, elem in array_data(pattern):
      if elem.kind == VkSymbol:
        let var_name = elem.str

        # Duplicate the array for extraction (keeps array on stack)
        self.emit(Instruction(kind: IkDup))
        # Get the i-th child - use i.to_value() to convert int to Value
        self.emit(Instruction(kind: IkGetChild, arg0: i.to_value()))

        # Store in variable
        let var_index = self.scope_tracker.next_index
        self.scope_tracker.mappings[var_name.to_key()] = var_index
        self.add_scope_start()
        self.scope_tracker.next_index.inc()
        self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
        # Pop the result of Var (which is the extracted value) to keep array on top
        self.emit(Instruction(kind: IkPop))
      else:
        not_allowed("Unsupported array pattern element type: " & $elem.kind & " (only symbols supported)")

    # Pop the original array
    self.emit(Instruction(kind: IkPop))

    # Push nil as the result of match
    self.emit(Instruction(kind: IkPushNil))

  elif pattern.kind == VkMap:
    # Map pattern matching: (match {^name ^age} person_data)

    # Store the value temporarily for property extraction
    self.emit(Instruction(kind: IkDup))

    # Iterate over map pairs using the pattern's map field
    for key, value in map_data(pattern).pairs:
      if value.kind == VkSymbol and value.str.startsWith("^"):
        # Property pattern: ^name -> binds to value of "name" key
        let prop_name = value.str[1..high(value.str)]  # Remove ^ prefix

        # Extract property using key from the target map
        self.emit(Instruction(kind: IkDup))  # Duplicate the target map
        self.emit(Instruction(kind: IkPushValue, arg0: key.to_value()))
        self.emit(Instruction(kind: IkGetMemberOrNil))  # Safe property access

        # Store in variable (use property name without ^)
        let var_index = self.scope_tracker.next_index
        self.scope_tracker.mappings[prop_name.to_key()] = var_index
        self.add_scope_start()
        self.scope_tracker.next_index.inc()
        self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
      else:
        not_allowed("Unsupported map pattern value: " & $value.kind & " (only ^property symbols supported)")

    # Pop the original map
    self.emit(Instruction(kind: IkPop))

    # Push nil as the result of match
    self.emit(Instruction(kind: IkPushNil))

  else:
    not_allowed("Unsupported pattern type: " & $pattern.kind)

proc compile_range(self: Compiler, gene: ptr Gene) =
  # (range start end) or (range start end step)
  if gene.children.len < 2:
    not_allowed("range requires at least 2 arguments")
  
  self.compile(gene.children[0])  # start
  self.compile(gene.children[1])  # end
  
  if gene.children.len >= 3:
    self.compile(gene.children[2])  # step
  else:
    self.emit(Instruction(kind: IkPushValue, arg0: NIL))  # default step
  
  self.emit(Instruction(kind: IkCreateRange))

proc compile_range_operator(self: Compiler, gene: ptr Gene) =
  # (a .. b) -> (range a b)
  if gene.children.len != 2:
    not_allowed(".. operator requires exactly 2 arguments")
  
  self.compile(gene.children[0])  # start
  self.compile(gene.children[1])  # end
  self.emit(Instruction(kind: IkPushValue, arg0: NIL))  # default step
  self.emit(Instruction(kind: IkCreateRange))

proc compile_gene_default(self: Compiler, gene: ptr Gene) {.inline.} =
  self.emit(Instruction(kind: IkGeneStart))
  self.compile(gene.type)
  self.emit(Instruction(kind: IkGeneSetType))

  # Handle properties with spread support
  for k, v in gene.props:
    let key_str = $k
    # Check for spread property: ^..., ^...1, ^...2, etc.
    if key_str.startsWith("..."):
      # Spread map into properties
      self.compile(v)
      self.emit(Instruction(kind: IkGenePropsSpread))
    else:
      # Normal property
      self.compile(v)
      self.emit(Instruction(kind: IkGeneSetProp, arg0: k))

  # Handle children with spread support
  var i = 0
  let children = gene.children
  while i < children.len:
    let child = children[i]

    # Check for standalone postfix spread: expr ...
    if i + 1 < children.len and children[i + 1].kind == VkSymbol and children[i + 1].str == "...":
      # Compile the expression and add with spread
      self.compile(child)
      self.emit(Instruction(kind: IkGeneAddSpread))
      i += 2  # Skip both the expr and the ... symbol
      continue

    # Check for suffix spread: a...
    if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
      # Compile the base symbol and add with spread
      let base_symbol = child.str[0..^4].to_symbol_value()  # Remove "..."
      self.compile(base_symbol)
      self.emit(Instruction(kind: IkGeneAddSpread))
      i += 1
      continue

    # Normal child - compile and add
    self.compile(child)
    self.emit(Instruction(kind: IkGeneAddChild))
    i += 1

  # compile_gene_default is used for literal Gene construction (quoted/_ forms).
  # It should never tail-call; always finish with IkGeneEnd.
  self.emit(Instruction(kind: IkGeneEnd))

# For a call that is unsure whether it is a function call or a macro call,
# we need to handle both cases and decide at runtime:
# * Compile type (use two labels to mark boundaries of two branches)
# * GeneCheckType Update code in place, remove incompatible branch
# * GeneStartMacro(fail if the type is not a macro)
# * Compile arguments assuming it is a macro call
# * FnLabel: GeneStart(fail if the type is not a function)
# * Compile arguments assuming it is a function call
# * GeneLabel: GeneEnd
# Similar logic is used for regular method calls and macro-method calls
proc compile_gene_unknown(self: Compiler, gene: ptr Gene) {.inline.} =
  # Special case: handle method calls like (obj .method ...)
  # These are parsed as genes with type obj/.method
  if gene.type.kind == VkComplexSymbol:
    let csym = gene.type.ref.csymbol
    # Check if this is a method access (second part starts with ".")
    if csym.len >= 2 and csym[1].starts_with("."):
      # This is a method call - compile it specially
      # The object will be on the stack after compiling the type
      # We need to ensure it's passed as the first argument
      let prev_mode = self.method_access_mode
      self.method_access_mode = MamReference
      try:
        self.compile(gene.type)  # This pushes object and method
      finally:
        self.method_access_mode = prev_mode
      
      # After compiling obj/.method, stack has [obj, method]
      # IkGeneStartDefault will pop the method
      # We need to ensure obj is used as an argument
      let fn_label = new_label()
      let end_label = if gene.children.len == 0 and gene.props.len == 0: fn_label else: new_label()
      self.emit(Instruction(kind: IkGeneStartDefault, arg0: fn_label.to_value()))
      
      # Swap so obj is on top, then add it as the first child
      self.emit(Instruction(kind: IkSwap))
      self.emit(Instruction(kind: IkGeneAddChild))
      
      # Add any explicit arguments
      self.quote_level.inc()

      # Handle properties with spread support
      for k, v in gene.props:
        let key_str = $k
        if key_str.startsWith("..."):
          self.compile(v)
          self.emit(Instruction(kind: IkGenePropsSpread))
        else:
          self.compile(v)
          self.emit(Instruction(kind: IkGeneSetProp, arg0: k))

      # Handle children with spread support
      var i = 0
      let children = gene.children
      while i < children.len:
        let child = children[i]

        # Check for standalone postfix spread: expr ...
        if i + 1 < children.len and children[i + 1].kind == VkSymbol and children[i + 1].str == "...":
          self.compile(child)
          self.emit(Instruction(kind: IkGeneAddSpread))
          i += 2
          continue

        # Check for suffix spread: a...
        if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
          let base_symbol = child.str[0..^4].to_symbol_value()
          self.compile(base_symbol)
          self.emit(Instruction(kind: IkGeneAddSpread))
          i += 1
          continue

        # Normal child
        self.compile(child)
        self.emit(Instruction(kind: IkGeneAddChild))
        i += 1

      self.quote_level.dec()
      
      self.emit(Instruction(kind: IkNoop, label: fn_label))
      self.emit(Instruction(kind: IkGeneEnd, label: end_label))
      return
  # Check for selector syntax: (target ./ property) or (target ./property)
  if DEBUG:
    echo "DEBUG: compile_gene_unknown: gene.type = ", gene.type
    echo "DEBUG: compile_gene_unknown: gene.children.len = ", gene.children.len
    if gene.children.len > 0:
      echo "DEBUG: compile_gene_unknown: first child = ", gene.children[0]
      if gene.children[0].kind == VkComplexSymbol:
        echo "DEBUG: compile_gene_unknown: first child csymbol = ", gene.children[0].ref.csymbol
  if gene.children.len >= 1:
    let first_child = gene.children[0]
    if first_child.kind == VkSymbol and first_child.str == "./":
      # Syntax: (target ./ property [default])
      if gene.children.len < 2 or gene.children.len > 3:
        not_allowed("(target ./ property [default]) expects 2 or 3 arguments")
      
      # Compile the target
      self.compile(gene.type)
      
      # Compile the property
      self.compile(gene.children[1])
      
      # If there's a default value, compile it
      if gene.children.len == 3:
        self.compile(gene.children[2])
        self.emit(Instruction(kind: IkGetMemberDefault))
      else:
        self.emit(Instruction(kind: IkGetMemberOrNil))
      return
    elif first_child.kind == VkComplexSymbol and first_child.ref.csymbol.len >= 2 and first_child.ref.csymbol[0] == ".":
      # Syntax: (target ./property) where ./property is a complex symbol
      if DEBUG:
        echo "DEBUG: Handling selector with complex symbol"
      # Compile the target
      self.compile(gene.type)
      
      # The property is the second part of the complex symbol
      let prop_name = first_child.ref.csymbol[1]
      # Check if property is numeric
      try:
        let idx = prop_name.parse_int()
        if DEBUG:
          echo "DEBUG: Property is numeric: ", idx
        self.emit(Instruction(kind: IkPushValue, arg0: idx.to_value()))
      except ValueError:
        if DEBUG:
          echo "DEBUG: Property is symbolic: ", prop_name
        self.emit(Instruction(kind: IkPushValue, arg0: prop_name.to_symbol_value()))
      
      # Check for default value (second child of gene)
      if gene.children.len == 2:
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkGetMemberDefault))
      else:
        self.emit(Instruction(kind: IkGetMemberOrNil))
      return
  
  let start_pos = self.output.instructions.len
  self.compile(gene.type)

  # if gene.args_are_literal():
  #   self.emit(Instruction(kind: IkGeneStartDefault))
  #   for k, v in gene.props:
  #     self.compile(v)
  #     self.emit(Instruction(kind: IkGeneSetProp, arg0: k))
  #   for child in gene.children:
  #     self.compile(child)
  #     self.emit(Instruction(kind: IkGeneAddChild))
  #   self.emit(Instruction(kind: IkGeneEnd))
  #   return

  # Fast path optimizations for regular function calls (no properties, not macro-like, no spreads)
  if gene.props.len == 0 and gene.type.kind == VkSymbol:
    let func_name = gene.type.str
    if (not func_name.ends_with("!")) and func_name notin ["return", "break", "continue", "throw", "aspect"]:
      var has_spread = false
      for k, _ in gene.props:
        if ($k).startsWith("..."):
          has_spread = true
          break
      if not has_spread:
        var i = 0
        while i < gene.children.len:
          let child = gene.children[i]
          if (i + 1 < gene.children.len and gene.children[i + 1].kind == VkSymbol and gene.children[i + 1].str == "...") or
             (child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3):
            has_spread = true
            break
          i += 1

      if not has_spread:
        if gene.children.len == 0:
          self.emit(Instruction(kind: IkUnifiedCall0))
          return
        if gene.children.len == 1:
          self.compile(gene.children[0])
          self.emit(Instruction(kind: IkUnifiedCall1))
          return
        for child in gene.children:
          self.compile(child)
        self.emit(Instruction(kind: IkUnifiedCall, arg1: gene.children.len.int32))
        return

  # Selector-based symbols are not macros; allow fast path when applicable
  var definitely_not_macro = false
  if gene.type.kind == VkGene and gene.type.gene.type == "@".to_symbol_value():
    definitely_not_macro = true
  elif gene.type.kind == VkComplexSymbol:
    let parts = gene.type.ref.csymbol
    if parts.len > 0 and parts[0].startsWith("@"):
      definitely_not_macro = true

  # Fast path when selector results are known non-macro and no properties
  if definitely_not_macro and gene.props.len == 0:
    if gene.children.len == 0:
      self.emit(Instruction(kind: IkUnifiedCall0))
      return
    if gene.children.len == 1:
      self.compile(gene.children[0])
      self.emit(Instruction(kind: IkUnifiedCall1))
      return
    for child in gene.children:
      self.compile(child)
    self.emit(Instruction(kind: IkUnifiedCall, arg1: gene.children.len.int32))
    return
  elif gene.props.len > 0 and gene.type.kind == VkSymbol and not gene.type.str.ends_with("!"):
    # Keyword argument fast path for eager functions (no spreads)
    var has_spread = false
    for k, _ in gene.props:
      if ($k).startsWith("..."):
        has_spread = true
        break
    if not has_spread:
      var i = 0
      while i < gene.children.len:
        let child = gene.children[i]
        if (i + 1 < gene.children.len and gene.children[i + 1].kind == VkSymbol and gene.children[i + 1].str == "...") or
           (child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3):
          has_spread = true
          break
        i.inc()

    if not has_spread:
      # Preserve evaluation order: properties first, then positional children
      for k, v in gene.props:
        self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](k)))
        self.compile(v)

      for child in gene.children:
        self.compile(child)

      let kw_count = gene.props.len.int32
      let total_items = (gene.children.len + gene.props.len * 2).int32
      self.emit(Instruction(kind: IkUnifiedCallKw, arg0: kw_count.to_value(), arg1: total_items))
      return

  # Dual-branch compilation:
  # - Macro branch (quoted args): for VkFunction with is_macro_like=true - continues to next instruction
  # - Function branch (evaluated args): for VkFunction with is_macro_like=false - jumps to fn_label
  # Runtime dispatch checks is_macro_like flag to determine which branch to use

  let fn_label = new_label()
  let end_label = if gene.children.len == 0 and gene.props.len == 0: fn_label else: new_label()
  self.emit(Instruction(kind: IkGeneStartDefault, arg0: fn_label.to_value()))

  # Macro branch: compile arguments as quoted (for macro-like functions)
  self.quote_level.inc()

  for k, v in gene.props:
    let key_str = $k
    if key_str.startsWith("..."):
      self.compile(v)
      self.emit(Instruction(kind: IkGenePropsSpread))
    else:
      self.compile(v)
      self.emit(Instruction(kind: IkGeneSetProp, arg0: k))

  block:
    var i = 0
    let children = gene.children
    while i < children.len:
      let child = children[i]
      if i + 1 < children.len and children[i + 1].kind == VkSymbol and children[i + 1].str == "...":
        self.compile(child)
        self.emit(Instruction(kind: IkGeneAddSpread))
        i += 2
        continue
      if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
        let base_symbol = child.str[0..^4].to_symbol_value()
        self.compile(base_symbol)
        self.emit(Instruction(kind: IkGeneAddSpread))
        i += 1
        continue
      self.compile(child)
      self.emit(Instruction(kind: IkGeneAddChild))
      i += 1

  self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))
  self.quote_level.dec()

  # Function branch: compile arguments as evaluated (for VkFunction)
  if fn_label != end_label:
    self.emit(Instruction(kind: IkNoop, label: fn_label))

  for k, v in gene.props:
    let key_str = $k
    if key_str.startsWith("..."):
      self.compile(v)
      self.emit(Instruction(kind: IkGenePropsSpread))
    else:
      self.compile(v)
      self.emit(Instruction(kind: IkGeneSetProp, arg0: k))

  block:
    var i = 0
    let children = gene.children
    while i < children.len:
      let child = children[i]
      if i + 1 < children.len and children[i + 1].kind == VkSymbol and children[i + 1].str == "...":
        self.compile(child)
        self.emit(Instruction(kind: IkGeneAddSpread))
        i += 2
        continue
      if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
        let base_symbol = child.str[0..^4].to_symbol_value()
        self.compile(base_symbol)
        self.emit(Instruction(kind: IkGeneAddSpread))
        i += 1
        continue
      self.compile(child)
      self.emit(Instruction(kind: IkGeneAddChild))
      i += 1

  let gene_end_label = if fn_label == end_label: fn_label else: end_label
  self.emit(Instruction(kind: IkGeneEnd, arg0: start_pos, label: gene_end_label))
  # echo fmt"Added GeneEnd with label {end_label} at position {self.output.instructions.len - 1}"

# TODO: handle special cases:
# 1. No arguments
# 2. All arguments are primitives or array/map of primitives
#
# self, method_name, arguments
# self + method_name => bounded_method_object (is composed of self, class, method_object(is composed of name, logic))
# (bounded_method_object ...arguments)

# Dynamic method call: (obj . method_expr args...)
# The method name is evaluated at runtime from method_expr
proc compile_dynamic_method_call(self: Compiler, gene: ptr Gene) =
  # gene.type = obj
  # gene.children[0] = . (operator symbol)
  # gene.children[1] = method_expr (to be evaluated for method name)
  # gene.children[2..] = args
  
  if gene.children.len < 2:
    not_allowed("Dynamic method call requires method expression: (obj . method_expr args...)")
  
  # Compile the object (will be on stack)
  self.compile(gene.type)
  
  # Compile the method expression (result will be method name string/symbol)
  self.compile(gene.children[1])
  
  # Compile additional arguments
  let arg_count = gene.children.len - 2  # exclude . and method_expr
  for i in 2..<gene.children.len:
    self.compile(gene.children[i])
  
  # Emit dynamic method call instruction with arg count
  self.emit(Instruction(kind: IkDynamicMethodCall, arg1: arg_count.int32))
proc compile_method_call(self: Compiler, gene: ptr Gene) {.inline.} =
  var method_name: string
  var method_value: Value
  var start_index = 0

  if gene.type.kind == VkSymbol and gene.type.str.starts_with("."):
    # (.method_name args...) - self is implicit
    method_name = gene.type.str[1..^1]
    method_value = method_name.to_symbol_value()
    self.emit(Instruction(kind: IkSelf))
  else:
    # (obj .method_name args...) - obj is explicit
    self.compile(gene.type)
    let first = gene.children[0]
    method_name = first.str[1..^1]
    method_value = method_name.to_symbol_value()
    start_index = 1  # Skip the method name when adding arguments

  let arg_count = gene.children.len - start_index

  # Check if this is a macro-like method (ends with !)
  let is_macro_like_method = method_name.ends_with("!")

  # Spread operator requires building a gene call (unified method calls don't support spreads)
  var has_spread = false
  for k, _ in gene.props:
    if ($k).startsWith("..."):
      has_spread = true
      break
  if not has_spread:
    var i = start_index
    while i < gene.children.len:
      let child = gene.children[i]
      if (i + 1 < gene.children.len and gene.children[i + 1].kind == VkSymbol and gene.children[i + 1].str == "...") or
         (child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3):
        has_spread = true
        break
      i += 1

  if has_spread:
    # Resolve method to a callable, then build args via gene add/spread.
    # This mirrors compile_gene_unknown's macro/function branching.
    self.emit(Instruction(kind: IkResolveMethod, arg0: method_value))
    let fn_label = new_label()
    let end_label = new_label()
    self.emit(Instruction(kind: IkGeneStartDefault, arg0: fn_label.to_value()))

    # Macro branch: quoted arguments
    self.emit(Instruction(kind: IkSwap))
    self.emit(Instruction(kind: IkGeneAddChild))
    self.quote_level.inc()
    for k, v in gene.props:
      let key_str = $k
      if key_str.startsWith("..."):
        self.compile(v)
        self.emit(Instruction(kind: IkGenePropsSpread))
      else:
        self.compile(v)
        self.emit(Instruction(kind: IkGeneSetProp, arg0: k))

    block:
      var i = start_index
      let children = gene.children
      while i < children.len:
        let child = children[i]
        if i + 1 < children.len and children[i + 1].kind == VkSymbol and children[i + 1].str == "...":
          self.compile(child)
          self.emit(Instruction(kind: IkGeneAddSpread))
          i += 2
          continue
        if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
          let base_symbol = child.str[0..^4].to_symbol_value()
          self.compile(base_symbol)
          self.emit(Instruction(kind: IkGeneAddSpread))
          i += 1
          continue
        self.compile(child)
        self.emit(Instruction(kind: IkGeneAddChild))
        i += 1

    self.quote_level.dec()
    self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))

    # Function branch: evaluated arguments
    self.emit(Instruction(kind: IkNoop, label: fn_label))
    self.emit(Instruction(kind: IkSwap))
    self.emit(Instruction(kind: IkGeneAddChild))
    for k, v in gene.props:
      let key_str = $k
      if key_str.startsWith("..."):
        self.compile(v)
        self.emit(Instruction(kind: IkGenePropsSpread))
      else:
        self.compile(v)
        self.emit(Instruction(kind: IkGeneSetProp, arg0: k))

    block:
      var i = start_index
      let children = gene.children
      while i < children.len:
        let child = children[i]
        if i + 1 < children.len and children[i + 1].kind == VkSymbol and children[i + 1].str == "...":
          self.compile(child)
          self.emit(Instruction(kind: IkGeneAddSpread))
          i += 2
          continue
        if child.kind == VkSymbol and child.str.endsWith("...") and child.str.len > 3:
          let base_symbol = child.str[0..^4].to_symbol_value()
          self.compile(base_symbol)
          self.emit(Instruction(kind: IkGeneAddSpread))
          i += 1
          continue
        self.compile(child)
        self.emit(Instruction(kind: IkGeneAddChild))
        i += 1

    self.emit(Instruction(kind: IkGeneEnd, label: end_label))
    return

  if gene.props.len == 0:
    # Fast path: positional arguments only
    # Compile arguments - they'll be on stack after object
    if is_macro_like_method:
      # For macro-like methods, pass arguments as unevaluated expressions
      self.quote_level.inc()
      for i in start_index..<gene.children.len:
        self.compile(gene.children[i])
      self.quote_level.dec()
    else:
      # For regular methods, evaluate arguments normally
      for i in start_index..<gene.children.len:
        self.compile(gene.children[i])

    # Use unified method call instructions
    if arg_count == 0:
      self.emit(Instruction(kind: IkUnifiedMethodCall0, arg0: method_value))
    elif arg_count == 1:
      self.emit(Instruction(kind: IkUnifiedMethodCall1, arg0: method_value))
    elif arg_count == 2:
      self.emit(Instruction(kind: IkUnifiedMethodCall2, arg0: method_value))
    else:
      let total_args = arg_count + 1  # include self
      self.emit(
        Instruction(
          kind: IkUnifiedMethodCall,
          arg0: method_value,
          arg1: total_args.int32,
        )
      )
    return

  # Fast path: method call with keyword arguments.
  # Stack layout expected by IkUnifiedMethodCallKw is:
  #   [obj, kw_key1, kw_val1, ..., kw_keyN, kw_valN, pos_arg1, ..., pos_argM]
  # Preserve evaluation order: keyword values first, then positional args.
  if is_macro_like_method:
    self.quote_level.inc()

  for k, v in gene.props:
    self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](k)))
    self.compile(v)

  for i in start_index..<gene.children.len:
    self.compile(gene.children[i])

  if is_macro_like_method:
    self.quote_level.dec()

  let kw_count = gene.props.len
  let total_items = arg_count + kw_count * 2
  if kw_count > 0xFFFF or total_items > 0xFFFF:
    not_allowed("Too many keyword arguments for unified method call")
  let packed = ((total_items shl 16) or kw_count).int32
  self.emit(Instruction(kind: IkUnifiedMethodCallKw, arg0: method_value, arg1: packed))
  return

proc compile_vm(self: Compiler, gene: ptr Gene) =
  if gene.props.len > 0:
    not_allowed("$vm does not accept properties")
  if gene.children.len != 1:
    not_allowed("$vm expects exactly 1 argument")
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    not_allowed("$vm builtin name must be a symbol")
  if name_val.str != "duration":
    not_allowed("Unknown $vm builtin: " & name_val.str)
  self.emit(Instruction(kind: IkVmDuration))

proc compile_gene(self: Compiler, input: Value) =
  let gene = input.gene
  
  # Special case: handle selector operator ./
  if not gene.type.is_nil():
    if DEBUG:
      echo "DEBUG: compile_gene: gene.type.kind = ", gene.type.kind
      if gene.type.kind == VkSymbol:
        echo "DEBUG: compile_gene: gene.type.str = '", gene.type.str, "'"
      elif gene.type.kind == VkComplexSymbol:
        echo "DEBUG: compile_gene: gene.type.csymbol = ", gene.type.ref.csymbol
    if gene.type.kind == VkSymbol and gene.type.str == "./":
      self.compile_selector(gene)
      return
    elif gene.type.kind == VkComplexSymbol and gene.type.ref.csymbol.len >= 2 and gene.type.ref.csymbol[0] == "." and gene.type.ref.csymbol[1] == "":
      # "./" is parsed as complex symbol @[".", ""]
      self.compile_selector(gene)
      return
  
  # Special case: handle range expressions like (0 .. 2)
  if gene.children.len == 2 and gene.children[0].kind == VkSymbol and gene.children[0].str == "..":
    # This is a range expression: (start .. end)
    self.compile(gene.type)  # start value
    self.compile(gene.children[1])  # end value
    self.emit(Instruction(kind: IkPushValue, arg0: NIL))  # default step
    self.emit(Instruction(kind: IkCreateRange))
    return
  
  # Special case: handle genes with numeric types and no children like (-1)
  if gene.children.len == 0 and gene.type.kind in {VkInt, VkFloat}:
    self.compile_literal(gene.type)
    return
  
  # Special case: super calls (positional-only fast path).
  # If keyword arguments are present, fall through so `super` becomes a runtime proxy
  # and keyword pairs can be forwarded via unified method call dispatch.
  if gene.type.kind == VkSymbol and gene.type.str == "super" and gene.props.len == 0:
    if gene.children.len == 0:
      not_allowed("super requires a member")
    let member = gene.children[0]
    if member.kind != VkSymbol:
      not_allowed("super requires a method or constructor symbol (e.g., .m or .ctor!)")
    if member.str == "ctor" or member.str == "ctor!":
      not_allowed("super constructor calls must use .ctor or .ctor!")
    if not member.str.starts_with("."):
      not_allowed("super requires a method or constructor symbol (e.g., .m or .ctor!)")
    let member_str = member.str
    let member_name = member_str[1..^1]  # strip leading dot
    let is_ctor = member_str == ".ctor" or member_str == ".ctor!"
    let is_macro = member_str.ends_with("!")
    let arg_start = 1
    let arg_count = gene.children.len - arg_start

    let old_tail = self.tail_position
    self.tail_position = false
    for i in arg_start..<gene.children.len:
      let arg = gene.children[i]
      # For macro super calls, forward plain symbols as-is (already unevaluated)
      let needs_quote = is_macro and arg.kind != VkSymbol
      if needs_quote:
        self.quote_level.inc()
      self.compile(arg)
      if needs_quote:
        self.quote_level.dec()
    self.tail_position = old_tail

    let inst_kind =
      if is_ctor:
        if is_macro: IkCallSuperCtorMacro else: IkCallSuperCtor
      else:
        if is_macro: IkCallSuperMethodMacro else: IkCallSuperMethod

    self.emit(
      Instruction(
        kind: inst_kind,
        arg0: member_name.to_symbol_value(),
        arg1: arg_count.int32,
      )
    )
    return

  let is_quoted_symbol_method_call = gene.type.kind == VkQuote and gene.type.ref.quote.kind == VkSymbol and
    gene.children.len >= 1 and gene.children[0].kind == VkSymbol and gene.children[0].str.starts_with(".")

  if self.quote_level > 0 or gene.type == "_".to_symbol_value() or (gene.type.kind == VkQuote and not is_quoted_symbol_method_call):
    self.compile_gene_default(gene)
    return

  let `type` = gene.type

    
  # Check for infix notation: (value operator args...)
  # This handles cases like (6 / 2) or (i + 1)
  if gene.children.len >= 1:
    let first_child = gene.children[0]
    if first_child.kind == VkSymbol:
      if first_child.str in ["+", "-", "*", "/", "%", "**", "./", "<", "<=", ">", ">=", "==", "!="]:
        # Don't convert if the type is already an operator or special form
        if `type`.kind != VkSymbol or `type`.str notin ["var", "if", "fn", "do", "loop", "while", "for", "ns", "class", "try", "throw", "import", "export", "$", "$vm", "$vmstmt", ".", "->", "@"]:
          # Convert infix to prefix notation and compile
          # (6 / 2) becomes (/ 6 2)
          # (i + 1) becomes (+ i 1)
          let prefix_gene = new_gene()
          prefix_gene.type = first_child  # operator becomes the type
          prefix_gene.children = @[`type`] & gene.children[1..^1]  # value and rest of args
          self.compile_gene(prefix_gene.to_gene_value())
          return
      elif first_child.str == ".":
        # Dynamic method call: (obj . method_expr args...)
        # Compile: obj on stack, evaluate method_expr to get method name, then call
        self.compile_dynamic_method_call(gene)
        return
      elif first_child.str.starts_with("."):
        # This is a method call: (obj .method args...)
        # Transform to method call format
        self.compile_method_call(gene)
        return
    elif first_child.kind == VkComplexSymbol and first_child.ref.csymbol.len >= 2 and first_child.ref.csymbol[0] == "." and first_child.ref.csymbol[1] == "":
      # Don't convert if the type is already an operator or special form
      if `type`.kind != VkSymbol or `type`.str notin ["var", "if", "fn", "do", "loop", "while", "for", "ns", "class", "try", "throw", "import", "export", "$", "$vm", "$vmstmt", ".", "->"]:
        # Convert infix to prefix notation and compile
        # (6 / 2) becomes (/ 6 2)
        # (i + 1) becomes (+ i 1)
        let prefix_gene = new_gene()
        prefix_gene.type = first_child  # operator becomes the type
        prefix_gene.children = @[`type`] & gene.children[1..^1]  # value and rest of args
        self.compile_gene(prefix_gene.to_gene_value())
        return
  
  # Check if type is an arithmetic operator
  if `type`.kind == VkSymbol:
    case `type`.str:
      of "+":
        if gene.children.len == 0:
          # (+) with no args returns 0
          self.emit(Instruction(kind: IkPushValue, arg0: 0.to_value()))
          return
        elif gene.children.len == 1:
          # Unary + is identity
          self.compile(gene.children[0])
          return
        elif gene.children.len == 2:
          if self.compile_var_op_literal(gene.children[0], gene.children[1], IkVarAddValue):
            return
          # Fall through to regular compilation
        # Multi-arg addition
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkAdd))
        return
      of "-":
        if gene.children.len == 0:
          not_allowed("- requires at least one argument")
        elif gene.children.len == 1:
          # Unary minus - use IkNeg instruction
          self.compile(gene.children[0])
          self.emit(Instruction(kind: IkNeg))
          return
        elif gene.children.len == 2:
          if self.compile_var_op_literal(gene.children[0], gene.children[1], IkVarSubValue):
            return
          # Fall through to regular compilation
        # Multi-arg subtraction
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkSub))
        return
      of "*":
        if gene.children.len == 0:
          # (*) with no args returns 1
          self.emit(Instruction(kind: IkPushValue, arg0: 1.to_value()))
          return
        elif gene.children.len == 1:
          # Unary * is identity
          self.compile(gene.children[0])
          return
        elif gene.children.len == 2:
          if self.compile_var_op_literal(gene.children[0], gene.children[1], IkVarMulValue):
            return
          # Fall through to regular compilation
        # Multi-arg multiplication
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkMul))
        return
      of "/":
        if gene.children.len == 0:
          not_allowed("/ requires at least one argument")
        elif gene.children.len == 1:
          # Unary / is reciprocal: 1/x
          self.emit(Instruction(kind: IkPushValue, arg0: 1.to_value()))
          self.compile(gene.children[0])
          self.emit(Instruction(kind: IkDiv))
          return
        elif gene.children.len == 2:
          if self.compile_var_op_literal(gene.children[0], gene.children[1], IkVarDivValue):
            return
          # Fall through to regular compilation
        # Multi-arg division
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkDiv))
        return
      of "<":
        # Binary less than
        if gene.children.len != 2:
          not_allowed("< requires exactly 2 arguments")
        let first = gene.children[0]
        let second = gene.children[1]
        if second.kind in {VkInt, VkFloat} and self.compile_var_op_literal(first, second, IkVarLtValue):
          return
        self.compile(first)
        self.compile(second)
        self.emit(Instruction(kind: IkLt))
        return
      of "<=":
        # Binary less than or equal
        if gene.children.len != 2:
          not_allowed("<= requires exactly 2 arguments")
        let first = gene.children[0]
        let second = gene.children[1]
        if second.kind in {VkInt, VkFloat} and self.compile_var_op_literal(first, second, IkVarLeValue):
          return
        self.compile(first)
        self.compile(second)
        self.emit(Instruction(kind: IkLe))
        return
      of ">":
        # Binary greater than
        if gene.children.len != 2:
          not_allowed("> requires exactly 2 arguments")
        let first = gene.children[0]
        let second = gene.children[1]
        if second.kind in {VkInt, VkFloat} and self.compile_var_op_literal(first, second, IkVarGtValue):
          return
        self.compile(first)
        self.compile(second)
        self.emit(Instruction(kind: IkGt))
        return
      of ">=":
        # Binary greater than or equal
        if gene.children.len != 2:
          not_allowed(">= requires exactly 2 arguments")
        let first = gene.children[0]
        let second = gene.children[1]
        if second.kind in {VkInt, VkFloat} and self.compile_var_op_literal(first, second, IkVarGeValue):
          return
        self.compile(first)
        self.compile(second)
        self.emit(Instruction(kind: IkGe))
        return
      of "==":
        # Binary equality
        if gene.children.len != 2:
          not_allowed("== requires exactly 2 arguments")
        let first = gene.children[0]
        let second = gene.children[1]
        if second.kind in {VkInt, VkFloat} and self.compile_var_op_literal(first, second, IkVarEqValue):
          return
        self.compile(first)
        self.compile(second)
        self.emit(Instruction(kind: IkEq))
        return
      of "!=":
        # Binary inequality
        if gene.children.len != 2:
          not_allowed("!= requires exactly 2 arguments")
        self.compile(gene.children[0])
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkNe))
        return
      else:
        discard  # Not an arithmetic operator, continue with normal processing
  
  if gene.children.len > 0:
    let first = gene.children[0]
    if first.kind == VkSymbol:
      case first.str:
        of "=", "+=", "-=":
          self.compile_assignment(gene)
          return
        of "&&":
          self.compile(`type`)
          self.compile(gene.children[1])
          self.emit(Instruction(kind: IkAnd))
          return
        of "||":
          self.compile(`type`)
          self.compile(gene.children[1])
          self.emit(Instruction(kind: IkOr))
          return
        of "?":
          # Postfix ? operator: (expr ?) - unwrap Ok/Some or return early
          self.compile(`type`)
          self.emit(Instruction(kind: IkTryUnwrap))
          return
        of "..":
          self.compile_range_operator(gene)
          return
        of "->":
          self.compile_block(input)
          return
        else:
          if first.str.starts_with("."):
            self.compile_method_call(gene)
            return

  if `type`.kind == VkSymbol:
    case `type`.str:
      of "do":
        self.compile_do(gene)
        return
      of "if":
        self.compile_if(gene)
        return
      of "case":
        self.compile_case(gene)
        return
      of "var":
        self.compile_var(gene)
        return
      of "loop":
        self.compile_loop(gene)
        return
      of "while":
        self.compile_while(gene)
        return
      of "repeat":
        self.compile_repeat(gene)
        return
      of "for":
        self.compile_for(gene)
        return
      of "enum":
        self.compile_enum(gene)
        return
      of "..":
        self.compile_range_operator(gene)
        return
      of "not":
        if gene.children.len != 1:
          when not defined(release):
            let trace = self.current_trace()
            if trace != nil:
              echo "DEBUG not arity (type): ", trace_location(trace)
            else:
              echo "DEBUG not arity (type): <no-trace>"
          not_allowed("not expects exactly 1 argument")
        self.compile_unary_not(gene.children[0])
        return
      of "break":
        self.compile_break(gene)
        return
      of "continue":
        self.compile_continue(gene)
        return
      of "fn":
        self.compile_fn(input)
        return
      of "fnx":
        not_allowed("fnx is no longer supported; use (fn [args] ...) instead")
      of "fnx!":
        not_allowed("fnx! is no longer supported; use (fn name! [args] ...) instead")
      of "fnxx":
        not_allowed("fnxx is no longer supported; use (fn [] ...) instead")
      of "->":
        self.compile_block(input)
        return
      of "block":
        self.compile_block(input)
        return
      of "return":
        self.compile_return(gene)
        return
      of "try":
        self.compile_try(gene)
        return
      of "throw":
        self.compile_throw(gene)
        return
      of "ns":
        self.compile_ns(gene)
        return
      of "class":
        self.compile_class(gene)
        return
      of "interface":
        # Compile-time only for now.
        self.emit(Instruction(kind: IkPushNil))
        return
      of "type":
        # Type aliases are compile-time only for now.
        self.emit(Instruction(kind: IkPushNil))
        return
      of "object":
        self.compile_object(gene)
        return
      of "new", "new!":
        self.compile_new(gene)
        return
      of "super":
        self.compile_super(gene)
        return
      of "match":
        self.compile_match(gene)
        return
      of "range":
        self.compile_range(gene)
        return
      of "async":
        self.compile_async(gene)
        return
      of "await":
        self.compile_await(gene)
        return
      of "spawn":
        self.compile_spawn(gene)
        return
      of "spawn_return":
        # spawn_return is an alias for (spawn ^return true expr) / (spawn ^^return expr)
        # Transform by setting the ^return prop
        var modified_gene = new_gene(gene.type)
        modified_gene.props = gene.props
        modified_gene.props["return".to_key()] = TRUE
        modified_gene.children = gene.children
        self.compile_spawn(modified_gene)
        return
      of "yield":
        self.compile_yield(gene)
        return
      of "void":
        # Compile all arguments but return nil
        for child in gene.children:
          if is_vmstmt_form(child):
            self.compile_vmstmt(child.gene)
          else:
            self.compile(child)
            self.emit(Instruction(kind: IkPop))
        self.emit(Instruction(kind: IkPushNil))
        return
      of "method":
        # Method definition inside class body
        self.compile_method_definition(gene)
        return
      of "method!":
        not_allowed("method! is not supported; use (method name! [args] ...) for macro-like methods")
      of "ctor", "ctor!":
        # Constructor definition inside class body
        self.compile_constructor_definition(gene)
        return
      of ".fn", ".fn!", ".ctor", ".ctor!":
        not_allowed("Legacy dotted class members are not supported; use (method ...) or (ctor ...) instead")
      of "eval":
        # Evaluate expressions
        if gene.children.len == 0:
          self.emit(Instruction(kind: IkPushNil))
        else:
          # Compile each argument and evaluate
          for i, child in gene.children:
            self.compile(child)
            # Add eval instruction to evaluate the value
            self.emit(Instruction(kind: IkEval))
            if i < gene.children.len - 1:
              self.emit(Instruction(kind: IkPop))
        return
      of "import":
        self.compile_import(gene)
        return
      of "export":
        self.compile_export(gene)
        return
      of "comptime":
        # Compile-time only; runtime ignores for now.
        self.emit(Instruction(kind: IkPushNil))
        return
      else:
        let s = `type`.str
        if s == "@":
          # Handle @ selector operator
          self.compile_at_selector(gene)
          return
        elif s.starts_with("."):
          # Check if this is a method definition (e.g., .fn, .ctor) or a method call
          if s == ".fn" or s == ".fn!" or s == ".ctor" or s == ".ctor!":
            not_allowed("Legacy dotted class members are not supported; use (method ...) or (ctor ...) instead")
          self.compile_method_call(gene)
          return
        elif s.starts_with("$"):
          # Handle $ prefixed operations
          case s:
            of "$with":
              self.compile_with(gene)
              return
            of "$tap":
              self.compile_tap(gene)
              return
            of "$parse":
              self.compile_parse(gene)
              return
            of "$caller_eval":
              self.compile_caller_eval(gene)
              return
            of "$set":
              self.compile_set(gene)
              return
            of "$vm":
              self.compile_vm(gene)
              return
            of "$vmstmt":
              not_allowed("$vmstmt is statement-only")
            of "$render":
              self.compile_render(gene)
              return
            of "$emit":
              self.compile_emit(gene)
              return
            of "$if_main":
              self.compile_if_main(gene)
              return

  self.compile_gene_unknown(gene)

proc compile*(self: Compiler, input: Value) =
  let trace =
    if input.kind == VkGene:
      input.gene.trace
    else:
      self.current_trace()
  let should_push = input.kind == VkGene and not trace.is_nil
  if should_push:
    self.push_trace(trace)
  defer:
    if should_push:
      self.pop_trace()
  
  try:
    case input.kind:
      of VkInt, VkBool, VkNil, VkFloat, VkChar:
        self.compile_literal(input)
      of VkString:
        self.compile_literal(input) # TODO
      of VkRegex:
        self.compile_literal(input)
      of VkSymbol:
        self.compile_symbol(input)
      of VkComplexSymbol:
        self.compile_complex_symbol(input)
      of VkQuote:
        self.quote_level.inc()
        self.compile(input.ref.quote)
        self.quote_level.dec()
      of VkStream:
        self.compile_stream(input)
      of VkArray:
        self.compile_array(input)
      of VkMap:
        self.compile_map(input)
      of VkSelector:
        self.compile_literal(input)
      of VkGene:
        self.compile_gene(input)
      of VkUnquote:
        # Unquote values should be compiled as literals
        # They will be processed during template rendering
        self.compile_literal(input)
      of VkFunction:
        # Functions should be compiled as literals
        self.compile_literal(input)
      else:
        not_allowed("Unsupported syntax: cannot compile value of type " & $input.kind)
  except CatchableError:
    if self.last_error_trace.is_nil:
      if not trace.is_nil:
        self.last_error_trace = trace
      else:
        self.last_error_trace = self.current_trace()
    raise

proc update_jumps(self: CompilationUnit) =
  # echo "update_jumps called, instruction count: ", self.instructions.len
  for i in 0..<self.instructions.len:
    let inst = self.instructions[i]
    case inst.kind
      of IkJump, IkJumpIfFalse, IkContinue, IkBreak, IkGeneStartDefault, IkRepeatInit, IkRepeatDecCheck:
        # Special case: -1 means no loop (for break/continue outside loops)
        if inst.kind in {IkBreak, IkContinue} and inst.arg0.int64 == -1:
          # Keep -1 as is for runtime checking
          discard
        else:
          # Labels are stored as int16 values converted to Value
          # Extract the int value and cast to Label (int16)
          # Extract the label from the NaN-boxed value
          # The label was stored as int16, so we need to extract just the low 16 bits
          when not defined(release):
            if inst.arg0.kind != VkInt:
              echo "ERROR: inst ", i, " (", inst.kind, ") arg0 is not an int: ", inst.arg0, " kind: ", inst.arg0.kind
          let label = (inst.arg0.int64.int and 0xFFFF).int16.Label
          let new_pc = self.find_label(label)
          # if inst.kind == IkGeneStartDefault:
          #   echo "  GeneStartDefault at ", i, ": label ", label, " -> PC ", new_pc
          self.instructions[i].arg0 = new_pc.to_value()
      of IkTryStart:
        # IkTryStart has arg0 for catch PC and optional arg1 for finally PC
        when not defined(release):
          if inst.arg0.kind != VkInt:
            echo "ERROR: inst ", i, " (", inst.kind, ") arg0 is not an int: ", inst.arg0, " kind: ", inst.arg0.kind
        let catch_label = (inst.arg0.int64.int and 0xFFFF).int16.Label
        let catch_pc = self.find_label(catch_label)
        self.instructions[i].arg0 = catch_pc.to_value()
        
        # Handle finally PC if present
        if inst.arg1 != 0:
          let finally_pc = self.find_label(inst.arg1.Label)
          self.instructions[i].arg1 = finally_pc.int32
      of IkJumpIfMatchSuccess:
        self.instructions[i].arg1 = self.find_label(inst.arg1.Label).int32
      else:
        discard

# Merge IkNoop instructions with following instructions before jump resolution
proc peephole_optimize(self: CompilationUnit) =
  # Apply peephole optimizations to convert common patterns to superinstructions
  self.ensure_trace_capacity()
  let old_traces = self.instruction_traces
  var new_instructions: seq[Instruction] = @[]
  var new_traces: seq[SourceTrace] = @[]
  var i = 0
  
  while i < self.instructions.len:
    let inst = self.instructions[i]
    let trace = if i < old_traces.len: old_traces[i] else: nil
    
    # Check for common patterns and replace with superinstructions
    if i + 2 < self.instructions.len:
      let next1 = self.instructions[i + 1]
      let next2 = self.instructions[i + 2]
      
      # Pattern: VAR_RESOLVE; ADD; VAR_ASSIGN -> IkAddLocal
      if inst.kind == IkVarResolve and next1.kind == IkAdd and next2.kind == IkVarAssign:
        if inst.arg0 == next2.arg0:  # Same variable
          new_instructions.add(Instruction(
            kind: IkAddLocal,
            arg0: inst.arg0,
            label: inst.label
          ))
          new_traces.add(trace)
          i += 3
          continue
    
    if i + 1 < self.instructions.len:
      let next1 = self.instructions[i + 1]
      
      # Pattern: INC_VAR (VAR_RESOLVE; ADD 1; VAR_ASSIGN)
      if inst.kind == IkVarResolve and next1.kind == IkAddValue:
        if i + 2 < self.instructions.len and self.instructions[i + 2].kind == IkVarAssign:
          if next1.arg0.kind == VkInt and next1.arg0.int64 == 1:
            new_instructions.add(Instruction(
              kind: IkIncLocal,
              arg0: inst.arg0,
              label: inst.label
            ))
            new_traces.add(trace)
            i += 3
            continue

      # Pattern: PUSH const; UNIFIEDCALL0; POP -> IkPushCallPop
      if inst.kind == IkPushValue and inst.arg0.kind == VkNativeFn and next1.kind == IkUnifiedCall0:
        if i + 2 < self.instructions.len and self.instructions[i + 2].kind == IkPop:
          new_instructions.add(Instruction(
            kind: IkPushCallPop,
            arg0: inst.arg0,
            label: inst.label
          ))
          new_traces.add(trace)
          i += 3
          continue
      
      # Pattern: RETURN NIL
      if inst.kind == IkPushNil and next1.kind == IkEnd:
        new_instructions.add(Instruction(
          kind: IkReturnNil,
          label: inst.label
        ))
        new_traces.add(trace)
        i += 2
        continue
    
    # No pattern matched, keep original instruction
    new_instructions.add(inst)
    new_traces.add(trace)
    i += 1
  
  self.instructions = new_instructions
  self.instruction_traces = new_traces

proc optimize_noops(self: CompilationUnit) =
  # Move labels from Noop instructions to the next real instruction
  # This must be done BEFORE jump resolution
  self.ensure_trace_capacity()
  let old_traces = self.instruction_traces
  var new_instructions: seq[Instruction] = @[]
  var new_traces: seq[SourceTrace] = @[]
  var pending_labels: seq[Label] = @[]
  var removed_count = 0

  for i, inst in self.instructions:
    let trace = if i < old_traces.len: old_traces[i] else: nil
    if inst.kind == IkNoop:
      if inst.label != 0:
        pending_labels.add(inst.label)
        removed_count.inc()
      elif inst.arg0.kind != VkNil:
        var modified_inst = inst
        if pending_labels.len > 0 and inst.label == 0:
          modified_inst.label = pending_labels[0]
          pending_labels.delete(0)
        new_instructions.add(modified_inst)
        new_traces.add(trace)
      else:
        removed_count.inc()
    else:
      var modified_inst = inst
      if pending_labels.len > 0:
        if inst.label == 0:
          modified_inst.label = pending_labels[0]
          if pending_labels.len > 1:
            for j in 1..<pending_labels.len:
              new_instructions.add(Instruction(kind: IkNoop, label: pending_labels[j]))
              new_traces.add(nil)
        else:
          for label in pending_labels:
            new_instructions.add(Instruction(kind: IkNoop, label: label))
            new_traces.add(nil)
        pending_labels = @[]
      new_instructions.add(modified_inst)
      new_traces.add(trace)

  for label in pending_labels:
    new_instructions.add(Instruction(kind: IkNoop, label: label))
    new_traces.add(nil)

  self.instructions = new_instructions
  self.instruction_traces = new_traces


proc compile*(input: seq[Value], eager_functions: bool): CompilationUnit =
  let self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    eager_functions: eager_functions,
    trace_stack: @[],
    method_access_mode: MamAutoCall
  )
  self.emit(Instruction(kind: IkStart))
  self.start_scope()

  for i, v in input:
    self.last_error_trace = nil
    try:
      self.compile(v)
    except CatchableError as e:
      var trace = self.last_error_trace
      if trace.is_nil and v.kind == VkGene:
        trace = v.gene.trace
      let location = trace_location(trace)
      let message = if location.len > 0: location & ": " & e.msg else: e.msg
      raise new_exception(types.Exception, message)
    if i < input.len - 1:
      self.emit(Instruction(kind: IkPop))

  self.end_scope()
  self.emit(Instruction(kind: IkEnd))
  self.output.optimize_noops()  # Optimize BEFORE resolving jumps
  # self.output.peephole_optimize()  # Apply peephole optimizations (temporarily disabled)
  self.output.update_jumps()
  result = self.output

proc compile*(input: seq[Value]): CompilationUnit =
  compile(input, false)

proc compile*(f: Function, eager_functions: bool) =
  if f.body_compiled != nil:
    return

  var self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    eager_functions: eager_functions,
    trace_stack: @[],
    method_access_mode: MamAutoCall
  )
  self.module_init_mode = f.name == "__init__"
  self.local_definitions = self.module_init_mode
  self.emit(Instruction(kind: IkStart))
  self.scope_trackers.add(f.scope_tracker)
  self.declared_names.add(initTable[Key, bool]())

  let param_count = f.matcher.children.len.int16
  if self.module_init_mode and param_count > 0 and self.scope_tracker.mappings.len > 0:
    let self_key = "self".to_key()
    let has_self = self.scope_tracker.mappings.has_key(self_key) and self.scope_tracker.mappings[self_key] == 0
    if not has_self:
      var shifted = initTable[Key, int16]()
      for k, v in self.scope_tracker.mappings:
        shifted[k] = v + param_count
      self.scope_tracker.mappings = shifted
      self.scope_tracker.next_index = self.scope_tracker.next_index + param_count

  # generate code for arguments
  for i, m in f.matcher.children:
    self.scope_tracker.mappings[m.name_key] = i.int16
    let label = new_label()
    self.emit(Instruction(
      kind: IkJumpIfMatchSuccess,
      arg0: i.to_value(),
      arg1: label,
    ))
    if m.default_value.kind != VkPlaceholder:
      self.compile(m.default_value)
      self.add_scope_start()
      self.emit(Instruction(kind: IkVar, arg0: i.to_value()))
      self.emit(Instruction(kind: IkPop))
    else:
      self.emit(Instruction(kind: IkThrow))
    self.emit(Instruction(kind: IkNoop, label: label))

  # Set next_index to reflect the number of parameters so child scopes can find them
  if f.matcher.children.len > 0:
    if self.scope_tracker.next_index < f.matcher.children.len.int16:
      self.scope_tracker.next_index = f.matcher.children.len.int16
    # Function frames with params already create a runtime scope; avoid extra ScopeStart.
    self.scope_tracker.scope_started = true

  # Mark that we're in tail position for the function body
  self.tail_position = true
  self.compile(f.body)
  self.tail_position = false

  self.end_scope()
  self.emit(Instruction(kind: IkEnd))
  self.output.optimize_noops()  # Optimize BEFORE resolving jumps
  self.output.peephole_optimize()  # Apply peephole optimizations
  self.output.update_jumps()
  self.output.kind = CkFunction
  f.body_compiled = self.output
  f.body_compiled.matcher = f.matcher

proc compile*(f: Function) =
  compile(f, false)

proc compile*(b: Block, eager_functions: bool) =
  if b.body_compiled != nil:
    return

  var self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    eager_functions: eager_functions,
    trace_stack: @[],
    method_access_mode: MamAutoCall
  )
  self.emit(Instruction(kind: IkStart))
  self.scope_trackers.add(b.scope_tracker)
  self.declared_names.add(initTable[Key, bool]())

  # generate code for arguments
  for i, m in b.matcher.children:
    self.scope_tracker.mappings[m.name_key] = i.int16
    let label = new_label()
    self.emit(Instruction(
      kind: IkJumpIfMatchSuccess,
      arg0: i.to_value(),
      arg1: label,
    ))
    if m.default_value.kind != VkPlaceholder:
      self.compile(m.default_value)
      self.add_scope_start()
      self.emit(Instruction(kind: IkVar, arg0: i.to_value()))
      self.emit(Instruction(kind: IkPop))
    else:
      self.emit(Instruction(kind: IkThrow))
    self.emit(Instruction(kind: IkNoop, label: label))

  # Set next_index to reflect the number of parameters so child scopes can find them
  if b.matcher.children.len > 0:
    self.scope_tracker.next_index = b.matcher.children.len.int16
    # Block frames with params already create a runtime scope; avoid extra ScopeStart.
    self.scope_tracker.scope_started = true

  self.compile(b.body)

  self.end_scope()
  self.emit(Instruction(kind: IkEnd))
  self.output.optimize_noops()  # Optimize BEFORE resolving jumps
  self.output.update_jumps()
  b.body_compiled = self.output
  b.body_compiled.matcher = b.matcher

proc compile*(b: Block) =
  compile(b, false)

proc compile_with(self: Compiler, gene: ptr Gene) =
  # ($with value body...)
  if gene.children.len < 1:
    not_allowed("$with expects at least 1 argument")
  
  # Compile the value that will become the new self
  self.compile(gene.children[0])
  
  # Duplicate it and save current self
  self.emit(Instruction(kind: IkDup))
  self.emit(Instruction(kind: IkSelf))
  self.emit(Instruction(kind: IkSwap))
  
  # Set as new self
  self.emit(Instruction(kind: IkSetSelf))
  
  # Compile body - return last value
  if gene.children.len > 1:
    for i in 1..<gene.children.len:
      self.compile(gene.children[i])
      if i < gene.children.len - 1:
        self.emit(Instruction(kind: IkPop))
  else:
    self.emit(Instruction(kind: IkPushNil))
  
  # Restore original self (which is on stack under the result)
  self.emit(Instruction(kind: IkSwap))
  self.emit(Instruction(kind: IkSetSelf))

proc compile_tap(self: Compiler, gene: ptr Gene) =
  # ($tap value body...) or ($tap value :name body...)
  if gene.children.len < 1:
    not_allowed("$tap expects at least 1 argument")

  # Compile the value
  self.compile(gene.children[0])
  
  # Duplicate it (one to return, one to use)
  self.emit(Instruction(kind: IkDup))
  
  # Check if there's a binding name
  var start_idx = 1
  var has_binding = false
  var binding_name: string
  
  if gene.children.len > 1 and gene.children[1].kind == VkSymbol and gene.children[1].str.starts_with(":"):
    has_binding = true
    binding_name = gene.children[1].str[1..^1]
    start_idx = 2
  
  # Save current self
  self.emit(Instruction(kind: IkSelf))
  
  # Set as new self
  self.emit(Instruction(kind: IkRotate))  # Rotate: original_self, dup_value, value -> value, original_self, dup_value
  self.emit(Instruction(kind: IkSetSelf))
  
  # If has binding, create a new scope and bind the value
  if has_binding:
    self.start_scope()
    let var_index = self.scope_tracker.next_index
    self.scope_tracker.mappings[binding_name.to_key()] = var_index
    self.add_scope_start()
    self.scope_tracker.next_index.inc()
    
    # Duplicate the value again for binding
    self.emit(Instruction(kind: IkSelf))
    self.emit(Instruction(kind: IkVar, arg0: var_index.to_value()))
  
  # Compile body
  if gene.children.len > start_idx:
    for i in start_idx..<gene.children.len:
      self.compile(gene.children[i])
      # Pop all but last result
      self.emit(Instruction(kind: IkPop))
  
  # End scope if we created one
  if has_binding:
    self.end_scope()
  
  # Restore original self
  self.emit(Instruction(kind: IkSwap))  # dup_value, original_self -> original_self, dup_value
  self.emit(Instruction(kind: IkSetSelf))
  # The dup_value remains on stack as the return value

proc compile_if_main(self: Compiler, gene: ptr Gene) =
  let cond_symbol = @["$ns", "__is_main__"].to_complex_symbol()

  # Compile the condition
  self.start_scope()
  self.compile(cond_symbol)
  let else_label = new_label()
  let end_label = new_label()
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: else_label.to_value()))

  # Compile then branch (the children of $if_main)
  self.start_scope()
  if gene.children.len > 0:
    for i, child in gene.children:
      let old_tail = self.tail_position
      if i == gene.children.len - 1:
        # Last expression preserves tail position
        discard
      else:
        self.tail_position = false
      self.compile(child)
      self.tail_position = old_tail
      if i < gene.children.len - 1:
        self.emit(Instruction(kind: IkPop))
  else:
    self.emit(Instruction(kind: IkPushValue, arg0: NIL))
  self.end_scope()
  self.emit(Instruction(kind: IkJump, arg0: end_label.to_value()))

  # Compile else branch (nil)
  self.emit(Instruction(kind: IkNoop, label: else_label))
  self.start_scope()
  self.emit(Instruction(kind: IkPushValue, arg0: NIL))
  self.end_scope()

  self.emit(Instruction(kind: IkNoop, label: end_label))
  self.end_scope()

proc compile_parse(self: Compiler, gene: ptr Gene) =
  # ($parse string)
  if gene.children.len != 1:
    not_allowed("$parse expects exactly 1 argument")
  
  # Compile the string argument
  self.compile(gene.children[0])
  
  # Parse it
  self.emit(Instruction(kind: IkParse))

proc compile_render(self: Compiler, gene: ptr Gene) =
  # ($render template)
  if gene.children.len != 1:
    not_allowed("$render expects exactly 1 argument")
  
  # Compile the template argument
  self.compile(gene.children[0])
  
  # Render it
  self.emit(Instruction(kind: IkRender))

proc compile_emit(self: Compiler, gene: ptr Gene) =
  # ($emit value) - used within templates to emit values
  if gene.children.len < 1:
    not_allowed("$emit expects at least 1 argument")
  
  # For now, $emit just evaluates to its argument
  # The actual emission logic is handled by the template renderer
  if gene.children.len == 1:
    self.compile(gene.children[0])
  else:
    # Multiple arguments - create an array
    let arr_gene = new_gene("Array".to_symbol_value())
    for child in gene.children:
      arr_gene.children.add(child)
    self.compile(arr_gene.to_gene_value())

proc compile_caller_eval(self: Compiler, gene: ptr Gene) =
  # ($caller_eval expr)
  if gene.children.len != 1:
    not_allowed("$caller_eval expects exactly 1 argument")
  
  # Compile the expression argument (will be evaluated in macro context first)
  self.compile(gene.children[0])
  
  # Then evaluate the result in caller's context
  self.emit(Instruction(kind: IkCallerEval))

proc compile_async(self: Compiler, gene: ptr Gene) =
  # (async expr)
  if gene.children.len != 1:
    not_allowed("async expects exactly 1 argument")
  
  # We need to wrap the expression evaluation in exception handling
  # Generate: try expr catch e -> future.fail(e)
  
  # Push a marker for the async block
  self.emit(Instruction(kind: IkAsyncStart))
  
  # Compile the expression
  self.compile(gene.children[0])
  
  # End async block - this will handle exceptions and wrap in future
  self.emit(Instruction(kind: IkAsyncEnd))

proc compile_await(self: Compiler, gene: ptr Gene) =
  # (await future) or (await future1 future2 ...)
  if gene.children.len == 0:
    not_allowed("await expects at least 1 argument")
  
  if gene.children.len == 1:
    # Single future
    self.compile(gene.children[0])
    self.emit(Instruction(kind: IkAwait))
  else:
    # Multiple futures - await each and collect results
    self.emit(Instruction(kind: IkArrayStart))
    for child in gene.children:
      self.compile(child)
      self.emit(Instruction(kind: IkAwait))
      # Awaited value is on stack, will be collected by IkArrayEnd
    self.emit(Instruction(kind: IkArrayEnd))

proc compile_spawn(self: Compiler, gene: ptr Gene) =
  # (spawn expr) - spawn thread to execute expression
  # (spawn ^return true expr) or (spawn ^^return expr) - spawn and return future
  if gene.children.len == 0:
    not_allowed("spawn expects at least 1 argument")

  var return_value = false
  # Use ^return / ^^return on props
  let return_key = "return".to_key()
  if gene.props.has_key(return_key):
    let v = gene.props[return_key]
    # Treat presence with NIL/placeholder as true, otherwise use bool value
    return_value = (v == NIL or v == PLACEHOLDER) or v.to_bool()

  let expr = gene.children[0]

  # Pass the Gene AST as-is to the thread (it will compile locally)
  # This avoids sharing CompilationUnit refs across threads
  self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](expr)))

  # Push return_value flag
  self.emit(Instruction(kind: IkPushValue, arg0: if return_value: TRUE else: FALSE))

  # Emit spawn instruction
  self.emit(Instruction(kind: IkSpawnThread))

proc compile_yield(self: Compiler, gene: ptr Gene) =
  # (yield value) - suspend generator and return value
  if gene.children.len == 0:
    # Yield without argument yields nil
    self.emit(Instruction(kind: IkPushNil))
  elif gene.children.len == 1:
    # Yield single value
    self.compile(gene.children[0])
  else:
    not_allowed("yield expects 0 or 1 argument")
  
  self.emit(Instruction(kind: IkYield))

proc compile_selector(self: Compiler, gene: ptr Gene) =
  # (./ target property [default])
  # ({^a "A"} ./ "a") -> "A"
  # ({} ./ "a" 1) -> 1 (default value)
  if gene.children.len < 2 or gene.children.len > 3:
    not_allowed("./ expects 2 or 3 arguments")
  
  # Compile the target
  self.compile(gene.children[0])
  
  # Compile the property/index
  self.compile(gene.children[1])
  
  # If there's a default value, compile it
  if gene.children.len == 3:
    self.compile(gene.children[2])
    self.emit(Instruction(kind: IkGetMemberDefault))
  else:
    self.emit(Instruction(kind: IkGetMemberOrNil))

proc compile_at_selector(self: Compiler, gene: ptr Gene) =
  # (@ "property") creates a selector
  # For now, we'll implement a simplified version
  # The full implementation would create a selector object
  
  # Since @ is used in contexts like ((@ "test") {^test 1}),
  # and this gets compiled as a function call where (@ "test") is the function
  # and {^test 1} is the argument, we need to handle this specially
  
  if gene.children.len == 0:
    not_allowed("@ expects at least 1 argument for selector creation")

  var segments: seq[Value] = @[]
  var all_literal = true
  for child in gene.children:
    case child.kind
    of VkString, VkSymbol, VkInt:
      segments.add(child)
    else:
      all_literal = false

  if all_literal:
    let selector_value = new_selector_value(segments)
    self.emit(Instruction(kind: IkPushValue, arg0: selector_value))
    return

  # Dynamic selector: evaluate non-literal segments at runtime, but treat
  # string/symbol/int children as literal selector segments (not variable lookups).
  for child in gene.children:
    case child.kind
    of VkString, VkSymbol, VkInt:
      self.emit(Instruction(kind: IkPushValue, arg0: child))
    else:
      self.compile(child)

  self.emit(Instruction(kind: IkCreateSelector, arg1: gene.children.len.int32))

proc compile_set(self: Compiler, gene: ptr Gene) =
  # ($set target @property value)
  # ($set a @test 1)
  if gene.children.len != 3:
    not_allowed("$set expects exactly 3 arguments")
  
  # Compile the target
  self.compile(gene.children[0])
  
  let selector_arg = gene.children[1]
  var segments: seq[Value] = @[]
  var dynamic_selector = false
  var dynamic_expr: Value = NIL

  if selector_arg.kind == VkSymbol and selector_arg.str.startsWith("@") and selector_arg.str.len > 1:
    let prop_name = selector_arg.str[1..^1]
    for part in prop_name.split("/"):
      if part.len == 0:
        not_allowed("$set selector segment cannot be empty")
      if part == "!":
        not_allowed("$set selector cannot contain !")
      try:
        let index = parseInt(part)
        segments.add(index.to_value())
      except ValueError:
        segments.add(part.to_value())
  elif selector_arg.kind == VkGene and selector_arg.gene.type == "@".to_symbol_value():
    if selector_arg.gene.children.len == 0:
      not_allowed("$set selector requires at least one segment")
    if selector_arg.gene.children.len == 1:
      let child = selector_arg.gene.children[0]
      case child.kind
      of VkString, VkSymbol, VkInt:
        segments.add(child)
      else:
        dynamic_selector = true
        dynamic_expr = child
    else:
      for child in selector_arg.gene.children:
        case child.kind
        of VkString, VkSymbol, VkInt:
          segments.add(child)
        else:
          not_allowed("Unsupported selector segment type: " & $child.kind)
  else:
    not_allowed("$set expects a selector (@property) as second argument")

  if dynamic_selector:
    if selector_arg.gene.children.len != 1:
      not_allowed("$set selector must have exactly one dynamic segment")
  else:
    if segments.len != 1:
      not_allowed("$set selector must have exactly one property")

  if dynamic_selector:
    # Compile dynamic selector key and value
    self.compile(dynamic_expr)
    self.compile(gene.children[2])
    self.emit(Instruction(kind: IkSetMemberDynamic))
    return

  let prop = segments[0]

  # Compile the value
  self.compile(gene.children[2])

  # Check if property is an integer (for array/gene child access)
  if prop.kind == VkInt:
    # Use SetChild for integer indices
    self.emit(Instruction(kind: IkSetChild, arg0: prop))
  else:
    # Use SetMember for string/symbol properties
    let prop_key = case prop.kind:
      of VkString: prop.str.to_key()
      of VkSymbol: prop.str.to_key()
      else: 
        not_allowed("Invalid property type for $set")
        "".to_key()  # Never reached, but satisfies type checker
    self.emit(Instruction(kind: IkSetMember, arg0: prop_key.to_value()))

proc compile_import(self: Compiler, gene: ptr Gene) =
  # (import a b from "module")
  # (import from "module" a b)
  # (import a:alias b from "module")
  # (import n/f from "module")
  # (import n/[one two] from "module")
  
  # echo "DEBUG: compile_import called for ", gene
  # echo "DEBUG: gene.children = ", gene.children
  # echo "DEBUG: gene.props = ", gene.props
  
  # Record module import metadata when compiling a module
  if self.preserve_root_scope:
    var module_path = ""
    var i = 0
    while i + 1 < gene.children.len:
      let child = gene.children[i]
      if child.kind == VkSymbol and child.str == "from":
        let next = gene.children[i + 1]
        if next.kind == VkString:
          module_path = next.str
        break
      i.inc()
    if module_path.len > 0:
      var exists = false
      for item in self.output.module_imports:
        if item == module_path:
          exists = true
          break
      if not exists:
        self.output.module_imports.add(module_path)

  # Compile a gene value for the import, but with "import" as a symbol type
  self.emit(Instruction(kind: IkGeneStart))
  self.emit(Instruction(kind: IkPushValue, arg0: "import".to_symbol_value()))
  self.emit(Instruction(kind: IkGeneSetType))
  
  # Compile the props
  for k, v in gene.props:
    self.emit(Instruction(kind: IkPushValue, arg0: v))
    self.emit(Instruction(kind: IkGeneSetProp, arg0: k))
  
  # Compile the children - they should be treated as quoted values
  for child in gene.children:
    # Import arguments are data, not code to execute
    # So compile them as literal values
    case child.kind:
    of VkSymbol, VkString:
      self.emit(Instruction(kind: IkPushValue, arg0: child))
    of VkComplexSymbol:
      # Handle n/f syntax
      self.emit(Instruction(kind: IkPushValue, arg0: child))
    of VkArray:
      # Handle [one two] part of n/[one two]
      self.emit(Instruction(kind: IkPushValue, arg0: child))
    of VkGene:
      # Handle complex forms like a:alias or n/[a b]
      self.compile_gene_default(child.gene)
    else:
      self.compile(child)
    self.emit(Instruction(kind: IkGeneAddChild))
  
  self.emit(Instruction(kind: IkGeneEnd))
  self.emit(Instruction(kind: IkImport))

proc compile_export(self: Compiler, gene: ptr Gene) =
  # (export [a b]) or (export a b)
  proc record_export(name: string) =
    if not self.preserve_root_scope or name.len == 0:
      return
    var exists = false
    for item in self.output.module_exports:
      if item == name:
        exists = true
        break
    if not exists:
      self.output.module_exports.add(name)

  var items: seq[Value] = @[]
  if gene.children.len == 1 and gene.children[0].kind == VkArray:
    items = array_data(gene.children[0])
  else:
    items = gene.children

  if items.len == 0:
    not_allowed("export expects at least one name")

  let export_list = new_array_value()
  for item in items:
    case item.kind
    of VkSymbol:
      if item.str.contains("/"):
        not_allowed("export names must be simple symbols")
      array_data(export_list).add(item)
      record_export(item.str)
    of VkString:
      if item.str.contains("/"):
        not_allowed("export names must be simple strings")
      array_data(export_list).add(item)
      record_export(item.str)
    else:
      not_allowed("export names must be symbols or strings")

  self.emit(Instruction(kind: IkExport, arg0: export_list))

proc compile_init*(input: Value, local_defs = false): CompilationUnit =
  let self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    trace_stack: @[],
    method_access_mode: MamAutoCall
  )
  self.local_definitions = local_defs
  self.output.skip_return = true
  self.emit(Instruction(kind: IkStart))
  self.start_scope()

  self.last_error_trace = nil
  try:
    if local_defs:
      var nodes: seq[Value] = @[]
      case input.kind
      of VkStream:
        nodes = input.ref.stream
      else:
        nodes = @[input]
      self.predeclare_local_defs(nodes)
    if input.kind == VkStream:
      self.compile_stream(input, true)
    else:
      self.compile(input)
  except CatchableError as e:
    var trace = self.last_error_trace
    if trace.is_nil and input.kind == VkGene:
      trace = input.gene.trace
    let location = trace_location(trace)
    let message = if location.len > 0: location & ": " & e.msg else: e.msg
    raise new_exception(types.Exception, message)

  self.end_scope()
  self.emit(Instruction(kind: IkEnd))
  self.output.optimize_noops()  # Optimize BEFORE resolving jumps
  # self.output.peephole_optimize()  # Apply peephole optimizations (temporarily disabled)
  self.output.update_jumps()
  result = self.output

proc replace_chunk*(self: var CompilationUnit, start_pos: int, end_pos: int, replacement: sink seq[Instruction]) =
  let replacement_count = replacement.len
  self.replace_traces_range(start_pos, end_pos, replacement_count)
  self.instructions[start_pos..end_pos] = replacement

proc is_module_def_node(v: Value): bool

type
  # Lightweight compile-time evaluator used to expand (comptime ...) blocks.
  ComptimeEnv = object
    vars: Table[string, Value]

  ComptimeResult = object
    value: Value
    emitted: seq[Value]

proc merge_emitted(dest: var seq[Value], src: seq[Value]) {.inline.} =
  if src.len > 0:
    dest.add(src)

proc new_comptime_env(): ComptimeEnv =
  ComptimeEnv(vars: initTable[string, Value]())

proc is_comptime_node(v: Value): bool =
  if v.kind != VkGene or v.gene == nil:
    return false
  let gt = v.gene.`type`
  gt.kind == VkSymbol and gt.str == "comptime"

proc eval_comptime_expr(expr: Value, env: var ComptimeEnv): ComptimeResult

proc eval_comptime_stream(stream_val: Value, env: var ComptimeEnv): ComptimeResult =
  result.value = NIL
  case stream_val.kind
  of VkStream:
    for item in stream_val.ref.stream:
      let r = eval_comptime_expr(item, env)
      merge_emitted(result.emitted, r.emitted)
      result.value = r.value
  else:
    result = eval_comptime_expr(stream_val, env)

proc comptime_add(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a) + to_int(b)).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) + to_float(b)).to_value()
  not_allowed("comptime: + expects numbers")

proc comptime_sub(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a) - to_int(b)).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) - to_float(b)).to_value()
  not_allowed("comptime: - expects numbers")

proc comptime_mul(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a) * to_int(b)).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) * to_float(b)).to_value()
  not_allowed("comptime: * expects numbers")

proc comptime_div(a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    return (to_int(a).float64 / to_int(b).float64).to_value()
  if is_float(a) or is_float(b):
    return (to_float(a) / to_float(b)).to_value()
  not_allowed("comptime: / expects numbers")

proc comptime_concat(a, b: Value): Value =
  if a.kind == VkString and b.kind == VkString:
    return new_str_value(a.str & b.str)
  not_allowed("comptime: ++ expects two strings")

proc comptime_compare(op: string, a, b: Value): Value =
  if is_small_int(a) and is_small_int(b):
    let ai = to_int(a)
    let bi = to_int(b)
    case op
    of "<": return (ai < bi).to_value()
    of "<=": return (ai <= bi).to_value()
    of ">": return (ai > bi).to_value()
    of ">=": return (ai >= bi).to_value()
    else: discard
  if is_float(a) or is_float(b):
    let af = to_float(a)
    let bf = to_float(b)
    case op
    of "<": return (af < bf).to_value()
    of "<=": return (af <= bf).to_value()
    of ">": return (af > bf).to_value()
    of ">=": return (af >= bf).to_value()
    else: discard
  if a.kind == VkString and b.kind == VkString:
    case op
    of "<": return (a.str < b.str).to_value()
    of "<=": return (a.str <= b.str).to_value()
    of ">": return (a.str > b.str).to_value()
    of ">=": return (a.str >= b.str).to_value()
    else: discard
  not_allowed("comptime: comparison expects numbers or strings")

proc eval_comptime_operator(op: string, args: seq[Value], env: var ComptimeEnv): ComptimeResult =
  case op
  of "=":
    if args.len != 2:
      not_allowed("comptime: = expects exactly 2 arguments")
    if args[0].kind != VkSymbol:
      not_allowed("comptime: assignment expects a symbol on the left")
    let r = eval_comptime_expr(args[1], env)
    merge_emitted(result.emitted, r.emitted)
    env.vars[args[0].str] = r.value
    result.value = r.value
    return
  of "+=", "-=":
    if args.len != 2 or args[0].kind != VkSymbol:
      not_allowed("comptime: compound assignment expects a symbol and a value")
    let current =
      if env.vars.hasKey(args[0].str): env.vars[args[0].str]
      else: NIL
    let rhs = eval_comptime_expr(args[1], env)
    merge_emitted(result.emitted, rhs.emitted)
    let new_val =
      if op == "+=": comptime_add(current, rhs.value)
      else: comptime_sub(current, rhs.value)
    env.vars[args[0].str] = new_val
    result.value = new_val
    return
  of "&&", "||":
    if args.len != 2:
      not_allowed("comptime: logical operator expects 2 arguments")
    let left = eval_comptime_expr(args[0], env)
    merge_emitted(result.emitted, left.emitted)
    if op == "&&":
      if not to_bool(left.value):
        result.value = FALSE
        return
    else:
      if to_bool(left.value):
        result.value = TRUE
        return
    let right = eval_comptime_expr(args[1], env)
    merge_emitted(result.emitted, right.emitted)
    result.value = (right.value != FALSE and right.value != NIL).to_value()
    return
  else:
    discard

  if args.len == 0:
    not_allowed("comptime: operator expects arguments")

  # Evaluate arguments before applying operator
  var values: seq[Value] = @[]
  for arg in args:
    let r = eval_comptime_expr(arg, env)
    merge_emitted(result.emitted, r.emitted)
    values.add(r.value)

  case op
  of "+":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_add(acc, values[i])
    result.value = acc
  of "-":
    if values.len == 1:
      if is_small_int(values[0]):
        result.value = (-to_int(values[0])).to_value()
      elif is_float(values[0]):
        result.value = (-to_float(values[0])).to_value()
      else:
        not_allowed("comptime: unary - expects number")
    else:
      var acc = values[0]
      for i in 1..<values.len:
        acc = comptime_sub(acc, values[i])
      result.value = acc
  of "*":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_mul(acc, values[i])
    result.value = acc
  of "/":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_div(acc, values[i])
    result.value = acc
  of "++":
    var acc = values[0]
    for i in 1..<values.len:
      acc = comptime_concat(acc, values[i])
    result.value = acc
  of "==":
    if values.len != 2:
      not_allowed("comptime: == expects exactly 2 arguments")
    result.value = (values[0] == values[1]).to_value()
  of "!=":
    if values.len != 2:
      not_allowed("comptime: != expects exactly 2 arguments")
    result.value = (values[0] != values[1]).to_value()
  of "<", "<=", ">", ">=":
    if values.len != 2:
      not_allowed("comptime: comparison expects exactly 2 arguments")
    result.value = comptime_compare(op, values[0], values[1])
  else:
    not_allowed("comptime: unsupported operator " & op)

proc eval_comptime_var(gene: ptr Gene, env: var ComptimeEnv): ComptimeResult =
  if gene.children.len == 0:
    result.value = NIL
    return
  var name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    not_allowed("comptime: var expects a symbol name")
  var name = name_val.str
  var value_index = 1
  if name.endsWith(":"):
    name = name[0..^2]
    if gene.children.len > 1:
      value_index = 2
  if gene.children.len > value_index:
    let r = eval_comptime_expr(gene.children[value_index], env)
    merge_emitted(result.emitted, r.emitted)
    env.vars[name] = r.value
    result.value = r.value
  else:
    env.vars[name] = NIL
    result.value = NIL

proc eval_comptime_if(gene: ptr Gene, env: var ComptimeEnv): ComptimeResult =
  normalize_if(gene)
  let cond_val = gene.props.get_or_default("cond".to_key(), NIL)
  let cond_res = eval_comptime_expr(cond_val, env)
  merge_emitted(result.emitted, cond_res.emitted)

  if cond_res.value:
    let then_stream = gene.props.get_or_default("then".to_key(), NIL)
    let then_res = eval_comptime_stream(then_stream, env)
    merge_emitted(result.emitted, then_res.emitted)
    result.value = then_res.value
    return

  if gene.props.hasKey("elif".to_key()):
    let elifs = array_data(gene.props["elif".to_key()])
    var i = 0
    while i + 1 < elifs.len:
      let elif_cond = eval_comptime_expr(elifs[i], env)
      merge_emitted(result.emitted, elif_cond.emitted)
      if elif_cond.value:
        let elif_body = eval_comptime_stream(elifs[i + 1], env)
        merge_emitted(result.emitted, elif_body.emitted)
        result.value = elif_body.value
        return
      i += 2

  let else_stream = gene.props.get_or_default("else".to_key(), NIL)
  let else_res = eval_comptime_stream(else_stream, env)
  merge_emitted(result.emitted, else_res.emitted)
  result.value = else_res.value

proc eval_comptime_env_call(gene: ptr Gene, env: var ComptimeEnv): ComptimeResult =
  if gene.children.len == 0:
    not_allowed("comptime: $env/get_env expects at least 1 argument")
  let name_res = eval_comptime_expr(gene.children[0], env)
  merge_emitted(result.emitted, name_res.emitted)
  let name =
    if name_res.value.kind == VkString:
      name_res.value.str
    elif name_res.value.kind == VkSymbol:
      name_res.value.str
    else:
      not_allowed("comptime: $env/get_env expects a string or symbol")
      ""
  let value = getEnv(name, "")
  if value == "":
    if gene.children.len > 1:
      let default_res = eval_comptime_expr(gene.children[1], env)
      merge_emitted(result.emitted, default_res.emitted)
      result.value = default_res.value
    else:
      result.value = NIL
  else:
    result.value = value.to_value()

proc eval_comptime_expr(expr: Value, env: var ComptimeEnv): ComptimeResult =
  case expr.kind
  of VkNil, VkVoid, VkBool, VkInt, VkFloat, VkChar, VkBytes, VkString, VkRegex, VkRange:
    result.value = expr
  of VkSymbol:
    if env.vars.hasKey(expr.str):
      result.value = env.vars[expr.str]
    else:
      not_allowed("comptime: unknown variable " & expr.str)
  of VkComplexSymbol:
    result.value = expr
  of VkQuote:
    result.value = expr.ref.quote
  of VkUnquote:
    if expr.ref.unquote_discard:
      let r = eval_comptime_expr(expr.ref.unquote, env)
      merge_emitted(result.emitted, r.emitted)
      result.value = NIL
    else:
      result = eval_comptime_expr(expr.ref.unquote, env)
  of VkArray:
    let out_val = new_array_value()
    for item in array_data(expr):
      let r = eval_comptime_expr(item, env)
      merge_emitted(result.emitted, r.emitted)
      array_data(out_val).add(r.value)
    result.value = out_val
  of VkMap:
    let out_val = new_map_value()
    for k, v in map_data(expr):
      let r = eval_comptime_expr(v, env)
      merge_emitted(result.emitted, r.emitted)
      map_data(out_val)[k] = r.value
    result.value = out_val
  of VkGene:
    let gene = expr.gene
    if gene == nil:
      result.value = NIL
      return

    # Infix notation: (x + y) => type=x, children=[+, y]
    if gene.children.len >= 1 and gene.children[0].kind == VkSymbol:
      let op = gene.children[0].str
      if op in ["+", "-", "*", "/", "%", "**", "./", "<", "<=", ">", ">=", "==", "!=", "&&", "||", "++", "=", "+=", "-="]:
        if gene.`type`.kind != VkSymbol or gene.`type`.str notin ["var", "if", "fn", "do", "loop", "while", "for", "ns", "class", "try", "throw", "import", "export", "interface", "comptime", "type", "object", "$", ".", "->", "@"]:
          let args = @[gene.`type`] & gene.children[1..^1]
          result = eval_comptime_operator(op, args, env)
          return

    if gene.`type`.kind == VkSymbol:
      case gene.`type`.str
      of "var":
        result = eval_comptime_var(gene, env)
        return
      of "do":
        if gene.children.len == 0:
          result.value = NIL
          return
        var last: ComptimeResult
        for child in gene.children:
          let r = eval_comptime_expr(child, env)
          merge_emitted(result.emitted, r.emitted)
          last = r
        result.value = last.value
        return
      of "if":
        result = eval_comptime_if(gene, env)
        return
      of "not":
        if gene.children.len != 1:
          not_allowed("comptime: not expects exactly 1 argument")
        let r = eval_comptime_expr(gene.children[0], env)
        merge_emitted(result.emitted, r.emitted)
        result.value = (not to_bool(r.value)).to_value()
        return
      of "comptime":
        for child in gene.children:
          let r = eval_comptime_expr(child, env)
          merge_emitted(result.emitted, r.emitted)
        result.value = NIL
        return
      of "$env", "get_env":
        result = eval_comptime_env_call(gene, env)
        return
      of "+", "-", "*", "/", "++", "==", "!=", "<", "<=", ">", ">=", "&&", "||":
        result = eval_comptime_operator(gene.`type`.str, gene.children, env)
        return
      else:
        discard

    if is_module_def_node(expr) and gene.`type`.kind == VkSymbol and gene.`type`.str != "comptime":
      result.emitted.add(expr)
      result.value = NIL
      return

    not_allowed("comptime: unsupported expression")
  else:
    result.value = expr

proc eval_comptime_block(node: Value, env: var ComptimeEnv): seq[Value] =
  if node.kind != VkGene or node.gene == nil:
    return @[]
  for child in node.gene.children:
    let r = eval_comptime_expr(child, env)
    merge_emitted(result, r.emitted)

proc expand_comptime_nodes(nodes: seq[Value], env: var ComptimeEnv): seq[Value] =
  for node in nodes:
    if is_comptime_node(node):
      let emitted = eval_comptime_block(node, env)
      if emitted.len > 0:
        result.add(expand_comptime_nodes(emitted, env))
    else:
      result.add(node)

proc is_module_def_node(v: Value): bool =
  if v.kind != VkGene or v.gene == nil:
    return false
  let gt = v.gene.`type`
  if gt.kind != VkSymbol:
    return false
  case gt.str:
  of "fn", "class", "ns", "enum", "type", "object", "import", "interface", "comptime":
    return true
  else:
    return false

proc is_module_init_fn(v: Value): bool =
  if v.kind != VkGene or v.gene == nil:
    return false
  let gt = v.gene.`type`
  if gt.kind != VkSymbol or gt.str != "fn":
    return false
  if v.gene.children.len == 0:
    return false
  let name = v.gene.children[0]
  case name.kind
  of VkSymbol, VkString:
    return name.str == "__init__"
  else:
    return false

proc append_init_items(init_fn: Value, items: seq[Value]) =
  if init_fn.kind != VkGene or init_fn.gene == nil:
    return
  for item in items:
    init_fn.gene.children.add(item)

proc ensure_init_self_arg(init_fn: Value) =
  if init_fn.kind != VkGene or init_fn.gene == nil:
    return
  if init_fn.gene.children.len < 2:
    return
  let args = init_fn.gene.children[1]
  var updated: Value = NIL
  case args.kind
  of VkArray:
    let src = array_data(args)
    if src.len == 0 or src[0].kind != VkSymbol or src[0].str != "self":
      updated = new_array_value()
      array_data(updated).add("self".to_symbol_value())
      for arg in src:
        array_data(updated).add(arg)
  of VkSymbol:
    if args.str == "self":
      discard
    else:
      updated = new_array_value()
      array_data(updated).add("self".to_symbol_value())
      if args.str != "_":
        array_data(updated).add(args)
  else:
    discard
  if updated != NIL:
    init_fn.gene.children[1] = updated

proc build_init_fn(items: seq[Value]): Value =
  let g = new_gene("fn".to_symbol_value())
  g.children.add("__init__".to_symbol_value())
  let args = new_array_value()
  array_data(args).add("self".to_symbol_value())
  g.children.add(args)
  for item in items:
    g.children.add(item)
  result = g.to_gene_value()

proc build_init_call(): Value =
  let g = new_gene("__init__".to_symbol_value())
  g.children.add("self".to_symbol_value())
  result = g.to_gene_value()

proc predeclare_local_defs(self: Compiler, nodes: seq[Value]) =
  if not self.local_definitions:
    return
  proc predeclare_name(name: string) =
    let key = name.to_key()
    if not self.scope_tracker.mappings.has_key(key):
      let index = self.scope_tracker.next_index
      self.scope_tracker.mappings[key] = index
      self.scope_tracker.next_index.inc()

  for node in nodes:
    if node.kind != VkGene or node.gene == nil:
      continue
    let gt = node.gene.`type`
    if gt.kind != VkSymbol:
      continue
    case gt.str
    of "fn":
      if node.gene.children.len == 0:
        continue
      let first = node.gene.children[0]
      let name = simple_def_name(first)
      if name.len > 0 and name != "__init__":
        predeclare_name(name)
    of "class", "ns", "object":
      if node.gene.children.len == 0:
        continue
      let name = simple_def_name(node.gene.children[0])
      if name.len > 0:
        predeclare_name(name)
    else:
      discard

proc predeclare_module_vars(self: Compiler, nodes: seq[Value]) =
  for node in nodes:
    if node.kind != VkGene or node.gene == nil:
      continue
    let gt = node.gene.`type`
    if gt.kind != VkSymbol or gt.str != "var":
      continue
    if node.gene.children.len == 0:
      continue
    let name_val = node.gene.children[0]
    if name_val.kind != VkSymbol:
      continue
    var name = name_val.str
    if name.len == 0:
      continue
    if name == "$ns":
      continue
    if name[0] == '$':
      continue
    if name.contains("/"):
      continue
    if name.endsWith(":"):
      if name.len <= 1:
        continue
      name = name[0..^2]
      if name.len == 0:
        continue
    let key = name.to_key()
    if not self.scope_tracker.mappings.has_key(key):
      let index = self.scope_tracker.next_index
      self.scope_tracker.mappings[key] = index
      self.scope_tracker.next_index.inc()

  # Predeclare local defs (fn/class/ns/object) for module mode when enabled.
  self.predeclare_local_defs(nodes)

proc normalize_module_nodes(nodes: seq[Value], run_init: bool): seq[Value] =
  var defs: seq[Value] = @[]
  var init_items: seq[Value] = @[]
  var init_fn: Value = NIL

  for node in nodes:
    if is_module_init_fn(node):
      if init_fn != NIL:
        not_allowed("Duplicate __init__ definition in module")
      ensure_init_self_arg(node)
      init_fn = node
      defs.add(node)
    elif is_module_def_node(node):
      defs.add(node)
    else:
      init_items.add(node)

  if init_items.len > 0:
    if init_fn != NIL:
      append_init_items(init_fn, init_items)
    else:
      let auto_init = build_init_fn(init_items)
      defs.add(auto_init)
      init_fn = auto_init

  if run_init and init_fn != NIL:
    defs.add(build_init_call())

  result = defs

# Parse and compile functions - unified interface for future streaming implementation
proc parse_and_compile*(input: string, filename = "<input>", eager_functions = false, type_check = true, module_mode = false, run_init = false): CompilationUnit =
  ## Parse and compile Gene code from a string with streaming compilation
  ## Parse one item -> compile immediately -> repeat

  var parser = new_parser()
  var stream = new_string_stream(input)
  parser.open(stream, filename)
  defer: parser.close()

  # Initialize compilation
  let self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    eager_functions: eager_functions,
    trace_stack: @[],
    method_access_mode: MamAutoCall
  )
  self.preserve_root_scope = module_mode
  self.local_definitions = module_mode
  self.emit(Instruction(kind: IkStart))
  self.start_scope()
  
  var is_first = true
  var prev_pushed = false
  # Gradual typing: non-strict mode allows unknown types (treated as Any)
  let checker = if type_check: new_type_checker(strict = false) else: nil

  if module_mode:
    let self_key = "self".to_key()
    if not self.scope_tracker.mappings.has_key(self_key):
      self.scope_tracker.mappings[self_key] = self.scope_tracker.next_index
      self.scope_tracker.next_index.inc()
    var nodes: seq[Value] = @[]
    try:
      while true:
        let node = parser.read()
        if node != PARSER_IGNORE:
          nodes.add(node)
    except ParseEofError:
      discard

    var comptime_env = new_comptime_env()
    let expanded = expand_comptime_nodes(nodes, comptime_env)
    self.predeclare_module_vars(expanded)
    if not self.scope_tracker.scope_started:
      self.emit(Instruction(kind: IkScopeStart, arg0: self.scope_tracker.to_value()))
      self.scope_tracker.scope_started = true
      self.started_scope_depth.inc()
    let normalized = normalize_module_nodes(expanded, run_init)
    for node in normalized:
      if not is_first and prev_pushed:
        self.emit(Instruction(kind: IkPop))

      self.last_error_trace = nil
      if checker != nil:
        try:
          checker.type_check_node(node)
        except CatchableError as e:
          var trace: SourceTrace = nil
          if node.kind == VkGene and node.gene != nil:
            trace = node.gene.trace
          let location = trace_location(trace)
          let message = if location.len > 0: location & ": " & e.msg else: e.msg
          raise new_exception(types.Exception, message)
      try:
        if is_vmstmt_form(node):
          self.compile_vmstmt(node.gene)
          prev_pushed = false
        else:
          self.compile(node)
          prev_pushed = true
        is_first = false
      except CatchableError as e:
        var trace = self.last_error_trace
        if trace.is_nil and node.kind == VkGene:
          trace = node.gene.trace
        let location = trace_location(trace)
        let message = if location.len > 0: location & ": " & e.msg else: e.msg
        raise new_exception(types.Exception, message)
  else:
    # Streaming compilation: parse one -> compile one -> repeat
    try:
      while true:
        let node = parser.read()
        if node != PARSER_IGNORE:
          # Pop previous result before compiling next item (except for first)
          if not is_first and prev_pushed:
            self.emit(Instruction(kind: IkPop))

          self.last_error_trace = nil
          if checker != nil:
            try:
              checker.type_check_node(node)
            except CatchableError as e:
              var trace: SourceTrace = nil
              if node.kind == VkGene and node.gene != nil:
                trace = node.gene.trace
              let location = trace_location(trace)
              let message = if location.len > 0: location & ": " & e.msg else: e.msg
              raise new_exception(types.Exception, message)
          try:
            # Compile current item
            if is_vmstmt_form(node):
              self.compile_vmstmt(node.gene)
              prev_pushed = false
            else:
              self.compile(node)
              prev_pushed = true
            is_first = false
          except CatchableError as e:
            var trace = self.last_error_trace
            if trace.is_nil and node.kind == VkGene:
              trace = node.gene.trace
            let location = trace_location(trace)
            let message = if location.len > 0: location & ": " & e.msg else: e.msg
            raise new_exception(types.Exception, message)
    except ParseEofError:
      # Expected end of input
      discard
  
  # Finalize compilation
  self.end_scope()
  self.emit(Instruction(kind: IkEnd))
  self.output.optimize_noops()
  self.output.update_jumps()
  self.output.ensure_trace_capacity()
  self.output.trace_root = parser.trace_root
  if module_mode:
    self.output.kind = CkModule
  
  return self.output

proc parse_and_compile_repl*(input: string, filename = "<repl>", scope_tracker: ScopeTracker, eager_functions = false, type_check = true): CompilationUnit =
  ## Parse and compile Gene code for REPL inputs with a persistent scope tracker.
  ## The REPL root scope is created outside of compiled code.

  var parser = new_parser()
  var stream = new_string_stream(input)
  parser.open(stream, filename)
  defer: parser.close()

  var root_tracker = scope_tracker
  if root_tracker.isNil:
    root_tracker = new_scope_tracker()
  root_tracker.scope_started = true

  let self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    eager_functions: eager_functions,
    trace_stack: @[],
    method_access_mode: MamAutoCall,
    scope_trackers: @[root_tracker],
    declared_names: @[initTable[Key, bool]()],
    skip_root_scope_start: true
  )
  self.emit(Instruction(kind: IkStart))

  var is_first = true
  var prev_pushed = false
  # Gradual typing: non-strict mode allows unknown types (treated as Any)
  let checker = if type_check: new_type_checker(strict = false) else: nil

  try:
    while true:
      let node = parser.read()
      if node != PARSER_IGNORE:
        if not is_first and prev_pushed:
          self.emit(Instruction(kind: IkPop))

        self.last_error_trace = nil
        if checker != nil:
          try:
            checker.type_check_node(node)
          except CatchableError as e:
            var trace: SourceTrace = nil
            if node.kind == VkGene and node.gene != nil:
              trace = node.gene.trace
            let location = trace_location(trace)
            let message = if location.len > 0: location & ": " & e.msg else: e.msg
            raise new_exception(types.Exception, message)
        try:
          if is_vmstmt_form(node):
            self.compile_vmstmt(node.gene)
            prev_pushed = false
          else:
            self.compile(node)
            prev_pushed = true
          is_first = false
        except CatchableError as e:
          var trace = self.last_error_trace
          if trace.is_nil and node.kind == VkGene:
            trace = node.gene.trace
          let location = trace_location(trace)
          let message = if location.len > 0: location & ": " & e.msg else: e.msg
          raise new_exception(types.Exception, message)
  except ParseEofError:
    discard

  self.emit(Instruction(kind: IkEnd))
  self.output.optimize_noops()
  self.output.update_jumps()
  self.output.ensure_trace_capacity()
  self.output.trace_root = parser.trace_root

  return self.output

proc parse_and_compile*(stream: Stream, filename = "<input>", eager_functions = false, type_check = true, module_mode = false, run_init = false): CompilationUnit =
  ## Parse and compile Gene code from a stream with streaming compilation
  ## This is more memory-efficient for large files as it doesn't load everything into memory
  ## Parse one item -> compile immediately -> repeat

  var parser = new_parser()
  parser.open(stream, filename)
  defer: parser.close()

  # Initialize compilation
  let self = Compiler(
    output: new_compilation_unit(),
    tail_position: false,
    eager_functions: eager_functions,
    trace_stack: @[],
    method_access_mode: MamAutoCall
  )
  self.preserve_root_scope = module_mode
  self.output.instructions.add(Instruction(kind: IkStart))
  self.start_scope()

  var is_first = true
  var prev_pushed = false
  # Gradual typing: non-strict mode allows unknown types (treated as Any)
  let checker = if type_check: new_type_checker(strict = false) else: nil

  if module_mode:
    let self_key = "self".to_key()
    if not self.scope_tracker.mappings.has_key(self_key):
      self.scope_tracker.mappings[self_key] = self.scope_tracker.next_index
      self.scope_tracker.next_index.inc()
    var nodes: seq[Value] = @[]
    try:
      while true:
        let node = parser.read()
        if node != PARSER_IGNORE:
          nodes.add(node)
    except ParseEofError:
      discard

    var comptime_env = new_comptime_env()
    let expanded = expand_comptime_nodes(nodes, comptime_env)
    self.predeclare_module_vars(expanded)
    if not self.scope_tracker.scope_started:
      self.emit(Instruction(kind: IkScopeStart, arg0: self.scope_tracker.to_value()))
      self.scope_tracker.scope_started = true
      self.started_scope_depth.inc()
    let normalized = normalize_module_nodes(expanded, run_init)
    for node in normalized:
      if not is_first and prev_pushed:
        self.output.instructions.add(Instruction(kind: IkPop))

      self.last_error_trace = nil
      if checker != nil:
        try:
          checker.type_check_node(node)
        except CatchableError as e:
          var trace: SourceTrace = nil
          if node.kind == VkGene and node.gene != nil:
            trace = node.gene.trace
          let location = trace_location(trace)
          let message = if location.len > 0: location & ": " & e.msg else: e.msg
          raise new_exception(types.Exception, message)
      try:
        # Compile current item
        if is_vmstmt_form(node):
          self.compile_vmstmt(node.gene)
          prev_pushed = false
        else:
          self.compile(node)
          prev_pushed = true
        is_first = false
      except CatchableError as e:
        var trace = self.last_error_trace
        if trace.is_nil and node.kind == VkGene:
          trace = node.gene.trace
        let location = trace_location(trace)
        let message = if location.len > 0: location & ": " & e.msg else: e.msg
        raise new_exception(types.Exception, message)
  else:
    # Streaming compilation: parse one -> compile one -> repeat
    try:
      while true:
        let node = parser.read()
        if node != PARSER_IGNORE:
          # Pop previous result before compiling next item (except for first)
          if not is_first and prev_pushed:
            self.output.instructions.add(Instruction(kind: IkPop))

          self.last_error_trace = nil
          if checker != nil:
            try:
              checker.type_check_node(node)
            except CatchableError as e:
              var trace: SourceTrace = nil
              if node.kind == VkGene and node.gene != nil:
                trace = node.gene.trace
              let location = trace_location(trace)
              let message = if location.len > 0: location & ": " & e.msg else: e.msg
              raise new_exception(types.Exception, message)
          try:
            # Compile current item
            if is_vmstmt_form(node):
              self.compile_vmstmt(node.gene)
              prev_pushed = false
            else:
              self.compile(node)
              prev_pushed = true
            is_first = false
          except CatchableError as e:
            var trace = self.last_error_trace
            if trace.is_nil and node.kind == VkGene:
              trace = node.gene.trace
            let location = trace_location(trace)
            let message = if location.len > 0: location & ": " & e.msg else: e.msg
            raise new_exception(types.Exception, message)
    except ParseEofError:
      # Expected end of input
      discard

  # Finalize compilation
  self.end_scope()
  self.output.instructions.add(Instruction(kind: IkEnd))
  self.output.optimize_noops()
  self.output.update_jumps()
  self.output.ensure_trace_capacity()
  self.output.trace_root = parser.trace_root
  if module_mode:
    self.output.kind = CkModule

  return self.output


# Compile methods for Function, Macro, and Block are defined above
