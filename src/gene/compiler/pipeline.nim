## Compilation pipeline and entry points:
## compile_init, predeclare_local_defs, predeclare_module_vars,
## module type helpers, normalize_module_nodes,
## parse_and_compile (all overloads), parse_and_compile_repl.
## Included from compiler.nim — shares its scope.

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

proc remap_checker_type_id(checker_type_id: TypeId,
                           checker_descs: seq[TypeDesc],
                           checker_to_output: var seq[TypeId],
                           checker_visiting: var seq[bool],
                           output_descs: var seq[TypeDesc],
                           output_desc_index: var Table[string, TypeId],
                           depth = 0): TypeId =
  if checker_type_id == NO_TYPE_ID:
    return NO_TYPE_ID
  if depth > 64:
    return BUILTIN_TYPE_ANY_ID

  let idx = checker_type_id.int
  if idx < 0 or idx >= checker_descs.len:
    return BUILTIN_TYPE_ANY_ID
  if checker_to_output[idx] != NO_TYPE_ID:
    return checker_to_output[idx]
  if checker_visiting[idx]:
    return BUILTIN_TYPE_ANY_ID

  checker_visiting[idx] = true
  let desc = checker_descs[idx]
  var mapped = desc

  case desc.kind
  of TdkApplied:
    var args: seq[TypeId] = @[]
    for arg in desc.args:
      args.add(remap_checker_type_id(arg, checker_descs, checker_to_output, checker_visiting,
                                     output_descs, output_desc_index, depth + 1))
    mapped = TypeDesc(kind: TdkApplied, ctor: desc.ctor, args: args)
  of TdkUnion:
    var members: seq[TypeId] = @[]
    for member in desc.members:
      members.add(remap_checker_type_id(member, checker_descs, checker_to_output, checker_visiting,
                                        output_descs, output_desc_index, depth + 1))
    mapped = TypeDesc(kind: TdkUnion, members: members)
  of TdkFn:
    var params: seq[TypeId] = @[]
    for param in desc.params:
      params.add(remap_checker_type_id(param, checker_descs, checker_to_output, checker_visiting,
                                       output_descs, output_desc_index, depth + 1))
    let ret = remap_checker_type_id(desc.ret, checker_descs, checker_to_output, checker_visiting,
                                    output_descs, output_desc_index, depth + 1)
    mapped = TypeDesc(kind: TdkFn, params: params, ret: ret, effects: desc.effects)
  else:
    discard

  let mapped_id = intern_type_desc(output_descs, mapped, output_desc_index)
  checker_to_output[idx] = mapped_id
  checker_visiting[idx] = false
  mapped_id

proc merge_checker_type_descriptors(output_descs: var seq[TypeDesc], checker_descs: seq[TypeDesc]) =
  ## Merge checker descriptors into compiler descriptors while preserving existing TypeIds.
  if checker_descs.len == 0:
    return

  var output_desc_index = initTable[string, TypeId]()
  ensure_type_desc_index(output_descs, output_desc_index)

  var checker_to_output = newSeq[TypeId](checker_descs.len)
  for i in 0..<checker_to_output.len:
    checker_to_output[i] = NO_TYPE_ID
  var checker_visiting = newSeq[bool](checker_descs.len)

  for i in 0..<checker_descs.len:
    discard remap_checker_type_id(i.TypeId, checker_descs, checker_to_output, checker_visiting,
                                  output_descs, output_desc_index)

## replace_chunk moved to compiler/optimize.nim
## comptime and is_module_def_node moved to compiler/comptime.nim

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

proc normalize_module_type_path(parts: seq[string]): seq[string] =
  for part in parts:
    if part.len == 0 or part == "$ns":
      continue
    result.add(part)

proc module_type_path_from_name(name: Value): seq[string] =
  case name.kind
  of VkSymbol, VkString:
    if name.str.contains("/"):
      return normalize_module_type_path(name.str.split("/"))
    if name.str.len > 0 and name.str != "$ns":
      return @[name.str]
    return @[]
  of VkComplexSymbol:
    return normalize_module_type_path(name.ref.csymbol)
  else:
    return @[]

proc ensure_module_type_child(nodes: var seq[ModuleTypeNode], name: string, default_kind: ModuleTypeKind): ModuleTypeNode =
  for node in nodes:
    if node != nil and node.name == name:
      return node
  let created = ModuleTypeNode(name: name, kind: default_kind, children: @[])
  nodes.add(created)
  return created

proc merge_module_type_kind(current: ModuleTypeKind, incoming: ModuleTypeKind): ModuleTypeKind =
  if incoming == MtkUnknown:
    return current
  if current == MtkUnknown:
    return incoming
  if current == MtkNamespace and incoming != MtkNamespace:
    return incoming
  return current

proc add_module_type_path(tree: var seq[ModuleTypeNode], path: seq[string], leaf_kind: ModuleTypeKind) =
  if path.len == 0:
    return

  var current = ensure_module_type_child(tree, path[0], if path.len == 1: leaf_kind else: MtkNamespace)
  if path.len == 1:
    current.kind = merge_module_type_kind(current.kind, leaf_kind)
    return

  for i in 1..<path.len:
    let is_leaf = i == path.high
    let desired_kind = if is_leaf: leaf_kind else: MtkNamespace
    current = ensure_module_type_child(current.children, path[i], desired_kind)
    if is_leaf:
      current.kind = merge_module_type_kind(current.kind, leaf_kind)

proc collect_module_type_nodes(node: Value, prefix: seq[string], tree: var seq[ModuleTypeNode])

proc collect_module_ns_children(children: seq[Value], prefix: seq[string], tree: var seq[ModuleTypeNode], start_index: int) =
  for i in start_index..<children.len:
    collect_module_type_nodes(children[i], prefix, tree)

proc collect_module_type_nodes(node: Value, prefix: seq[string], tree: var seq[ModuleTypeNode]) =
  if node.kind != VkGene or node.gene == nil:
    return

  let gene = node.gene
  let gt = gene.`type`
  if gt.kind != VkSymbol:
    return

  case gt.str
  of "ns":
    if gene.children.len == 0:
      return
    let path = module_type_path_from_name(gene.children[0])
    if path.len == 0:
      return
    let full_path = prefix & path
    add_module_type_path(tree, full_path, MtkNamespace)
    collect_module_ns_children(gene.children, full_path, tree, 1)
  of "class":
    if gene.children.len == 0:
      return
    let path = module_type_path_from_name(gene.children[0])
    if path.len == 0:
      return
    let full_path = prefix & path
    add_module_type_path(tree, full_path, MtkClass)
    var body_start = 1
    if gene.children.len >= 3 and gene.children[1] == "<".to_symbol_value():
      body_start = 3
    collect_module_ns_children(gene.children, full_path, tree, body_start)
  of "object":
    if gene.children.len == 0:
      return
    let path = module_type_path_from_name(gene.children[0])
    if path.len == 0:
      return
    let full_path = prefix & path
    add_module_type_path(tree, full_path, MtkObject)
    var body_start = 1
    if gene.children.len >= 3 and gene.children[1] == "<".to_symbol_value():
      body_start = 3
    collect_module_ns_children(gene.children, full_path, tree, body_start)
  of "enum":
    if gene.children.len == 0:
      return
    let path = module_type_path_from_name(gene.children[0])
    if path.len == 0:
      return
    add_module_type_path(tree, prefix & path, MtkEnum)
  of "interface":
    if gene.children.len == 0:
      return
    let path = module_type_path_from_name(gene.children[0])
    if path.len == 0:
      return
    add_module_type_path(tree, prefix & path, MtkInterface)
  of "type":
    if gene.children.len < 2:
      return
    let path = module_type_path_from_name(gene.children[0])
    if path.len == 0:
      return
    add_module_type_path(tree, prefix & path, MtkAlias)
  else:
    discard

proc collect_module_types(nodes: seq[Value]): seq[ModuleTypeNode] =
  var tree: seq[ModuleTypeNode] = @[]
  for node in nodes:
    collect_module_type_nodes(node, @[], tree)
  return tree

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
  self.output.type_check = type_check
  self.emit(Instruction(kind: IkStart))
  self.start_scope()

  var is_first = true
  var prev_pushed = false
  # Gradual typing: non-strict mode allows unknown types (treated as Any)
  let checker = if type_check: new_type_checker(strict = false, module_filename = filename) else: nil

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
    self.output.module_types = collect_module_types(normalized)
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
        # Emit compile-time type warnings (gradual mode)
        let warnings = checker.flush_warnings()
        for w in warnings:
          var trace: SourceTrace = nil
          if node.kind == VkGene and node.gene != nil:
            trace = node.gene.trace
          let location = trace_location(trace)
          if location.len > 0:
            stderr.writeLine(location & ": " & w)
          else:
            stderr.writeLine(w)
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
            # Emit compile-time type warnings (gradual mode)
            let warnings = checker.flush_warnings()
            for w in warnings:
              var trace: SourceTrace = nil
              if node.kind == VkGene and node.gene != nil:
                trace = node.gene.trace
              let location = trace_location(trace)
              if location.len > 0:
                stderr.writeLine(location & ": " & w)
              else:
                stderr.writeLine(w)
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
  if checker != nil:
    merge_checker_type_descriptors(self.output.type_descriptors, checker.type_descriptors())
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
  self.output.type_check = type_check
  self.emit(Instruction(kind: IkStart))

  var is_first = true
  var prev_pushed = false
  # Gradual typing: non-strict mode allows unknown types (treated as Any)
  let checker = if type_check: new_type_checker(strict = false, module_filename = filename) else: nil

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
          # Emit compile-time type warnings (gradual mode)
          let warnings = checker.flush_warnings()
          for w in warnings:
            var trace: SourceTrace = nil
            if node.kind == VkGene and node.gene != nil:
              trace = node.gene.trace
            let location = trace_location(trace)
            if location.len > 0:
              stderr.writeLine(location & ": " & w)
            else:
              stderr.writeLine(w)
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
  if checker != nil:
    merge_checker_type_descriptors(self.output.type_descriptors, checker.type_descriptors())

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
  self.output.type_check = type_check
  self.output.instructions.add(Instruction(kind: IkStart))
  self.start_scope()

  var is_first = true
  var prev_pushed = false
  # Gradual typing: non-strict mode allows unknown types (treated as Any)
  let checker = if type_check: new_type_checker(strict = false, module_filename = filename) else: nil

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
    self.output.module_types = collect_module_types(normalized)
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
        # Emit compile-time type warnings (gradual mode)
        let warnings = checker.flush_warnings()
        for w in warnings:
          var trace: SourceTrace = nil
          if node.kind == VkGene and node.gene != nil:
            trace = node.gene.trace
          let location = trace_location(trace)
          if location.len > 0:
            stderr.writeLine(location & ": " & w)
          else:
            stderr.writeLine(w)
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
            # Emit compile-time type warnings (gradual mode)
            let warnings = checker.flush_warnings()
            for w in warnings:
              var trace: SourceTrace = nil
              if node.kind == VkGene and node.gene != nil:
                trace = node.gene.trace
              let location = trace_location(trace)
              if location.len > 0:
                stderr.writeLine(location & ": " & w)
              else:
                stderr.writeLine(w)
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
  if checker != nil:
    merge_checker_type_descriptors(self.output.type_descriptors, checker.type_descriptors())
  if module_mode:
    self.output.kind = CkModule

  return self.output


# Compile methods for Function, Macro, and Block are defined above
