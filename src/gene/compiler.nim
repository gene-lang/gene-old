import tables, strutils, streams, os

import ./types
import ./parser
import ./type_checker
import "./compiler/if"
import "./compiler/case"
import "./compiler/comptime"
import "./compiler/optimize"
export comptime
export optimize

const DEBUG = false

proc container_key(): Key {.inline.} =
  "container".to_key()

proc local_def_key(): Key {.inline.} =
  "local_def".to_key()

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

#################### Forward Declarations #################
proc compile*(self: Compiler, input: Value)
proc compile*(f: Function, eager_functions: bool)
proc compile*(b: Block, eager_functions: bool)
proc compile_init*(input: Value, local_defs = false, module_path = ""): CompilationUnit
proc predeclare_local_defs(self: Compiler, nodes: seq[Value])
# Forward declarations for procs in included submodules (misc, async, modules)
# needed by compile_gene which is defined before the include points
proc compile_vmstmt(self: Compiler, gene: ptr Gene)
proc compile_vm(self: Compiler, gene: ptr Gene)
proc compile_with(self: Compiler, gene: ptr Gene)
proc compile_tap(self: Compiler, gene: ptr Gene)
proc compile_if_main(self: Compiler, gene: ptr Gene)
proc compile_parse(self: Compiler, gene: ptr Gene)
proc compile_render(self: Compiler, gene: ptr Gene)
proc compile_emit(self: Compiler, gene: ptr Gene)
proc compile_caller_eval(self: Compiler, gene: ptr Gene)
proc compile_selector(self: Compiler, gene: ptr Gene)
proc compile_at_selector(self: Compiler, gene: ptr Gene)
proc compile_set(self: Compiler, gene: ptr Gene)
proc compile_async(self: Compiler, gene: ptr Gene)
proc compile_await(self: Compiler, gene: ptr Gene)
proc compile_spawn(self: Compiler, gene: ptr Gene)
proc compile_yield(self: Compiler, gene: ptr Gene)
proc compile_import(self: Compiler, gene: ptr Gene)
proc compile_export(self: Compiler, gene: ptr Gene)

proc is_vmstmt_form(input: Value): bool =
  input.kind == VkGene and
    input.gene.`type`.kind == VkSymbol and
    input.gene.`type`.str == "$vmstmt"

## compile_vmstmt moved to compiler/misc.nim
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

## compile_array, compile_stream, compile_map moved to compiler/collections.nim
include "./compiler/collections"

# Forward declarations for scope helpers used below
proc start_scope(self: Compiler)
proc add_scope_start(self: Compiler)
proc end_scope(self: Compiler)

include "./compiler/control_flow"

include "./compiler/functions"

include "./compiler/operators"

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

## update_jumps, peephole_optimize, optimize_noops moved to compiler/optimize.nim


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

  self.contract_fn_name = f.name
  self.contract_post_conditions = @[]
  self.contract_result_slot = -1

  for i, condition in f.pre_conditions:
    self.compile_contract_check(condition, "pre", f.name, i + 1)

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
  if f.matcher != nil and f.matcher.type_descriptors.len > 0:
    self.output.type_descriptors = f.matcher.type_descriptors
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
  if b.matcher != nil and b.matcher.type_descriptors.len > 0:
    self.output.type_descriptors = b.matcher.type_descriptors
  b.body_compiled = self.output
  b.body_compiled.matcher = b.matcher

proc compile*(b: Block) =
  compile(b, false)

## Included submodules: misc (with/tap/if_main/parse/render/emit/caller_eval/selector/set/vm/vmstmt),
## async (async/await/spawn/yield), modules (import/export)
include "./compiler/misc"
include "./compiler/async"
include "./compiler/modules"


include "./compiler/pipeline"
