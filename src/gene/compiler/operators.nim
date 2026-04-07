## Gene expression dispatch and operator compilation:
## compile_gene_default, compile_gene_unknown,
## compile_dynamic_method_call, compile_method_call, compile_gene.
## Included from compiler.nim — shares its scope.

## compile_range, compile_range_operator moved to compiler/collections.nim
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
  var flags = 1'i32
  if gene.frozen:
    flags = flags or 2'i32
  self.emit(Instruction(kind: IkGeneEnd, arg1: flags))

# For a call that is unsure whether it is a function call or a macro call,
# we need to handle both cases and decide at runtime:
# * Compile type (use two labels to mark boundaries of two branches)
# * GeneCheckType Update code in place, remove incompatible branch
# * GeneStartMacro(fail if the type is not a macro)
# * Compile arguments assuming it is a macro call
# * FnLabel: GeneStart(fail if the type is not a function)
# * Compile arguments assuming it is a function call
# * GeneLabel: GeneEnd
proc compile_gene_unknown(self: Compiler, gene: ptr Gene) {.inline.} =
  # Special case: handle method calls like (obj .method ...)
  # These are parsed as genes with type obj/.method
  if gene.type.kind == VkComplexSymbol:
    let csym = gene.type.ref.csymbol
    # Check if this is a method access (second part starts with ".")
    if csym.len >= 2 and csym[1].starts_with("."):
      if csym[1].startsWith(".<"):
        if gene.children.len > 0 or gene.props.len > 0:
          not_allowed("Dynamic method sugar only supports zero-argument calls; use (obj . expr args...)")
        self.compile(gene.type)
        return
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
    compiler_log(LlDebug, "compile_gene_unknown: gene.type = " & $gene.type)
    compiler_log(LlDebug, "compile_gene_unknown: gene.children.len = " & $gene.children.len)
    if gene.children.len > 0:
      compiler_log(LlDebug, "compile_gene_unknown: first child = " & $gene.children[0])
      if gene.children[0].kind == VkComplexSymbol:
        compiler_log(LlDebug, "compile_gene_unknown: first child csymbol = " & $gene.children[0].ref.csymbol)
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
      self.emit(Instruction(kind: IkValidateSelectorSegment))
      
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
        compiler_log(LlDebug, "Handling selector with complex symbol")
      # Compile the target
      self.compile(gene.type)
      
      # The property is the second part of the complex symbol
      let prop_name = first_child.ref.csymbol[1]
      # Check if property is numeric
      try:
        let idx = prop_name.parse_int()
        if DEBUG:
          compiler_log(LlDebug, "Property is numeric: " & $idx)
        self.emit(Instruction(kind: IkPushValue, arg0: idx.to_value()))
      except ValueError:
        if DEBUG:
          compiler_log(LlDebug, "Property is symbolic: " & prop_name)
        self.emit(Instruction(kind: IkPushValue, arg0: prop_name.to_symbol_value()))
      self.emit(Instruction(kind: IkValidateSelectorSegment))
      
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
  let call_kind = if self.tail_position: IkTailCall else: IkGeneEnd
  self.emit(Instruction(kind: call_kind, arg0: start_pos, label: gene_end_label))
  # echo fmt"Added GeneEnd with label {end_label} at position {self.output.instructions.len - 1}"

proc likely_runtime_type_leaf(self: Compiler, value: Value): bool =
  case value.kind
  of VkSymbol:
    let name = value.str
    if self.output.type_aliases.hasKey(name):
      return true
    if lookup_builtin_type(name) != NO_TYPE_ID:
      return true
    if name.len > 0 and name[0].isUpperAscii():
      return true
    false
  else:
    false

proc likely_runtime_type_head(self: Compiler, value: Value): bool =
  case value.kind
  of VkSymbol:
    let name = value.str
    if name == "Fn":
      return true
    if self.output.type_aliases.hasKey(name):
      return true
    if lookup_builtin_type(name) != NO_TYPE_ID:
      return true
    false
  else:
    false

proc is_union_type_gene(gene: ptr Gene): bool =
  if gene == nil:
    return false
  if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
    return true
  for child in gene.children:
    if child.kind == VkSymbol and child.str == "|":
      return true
  false

proc union_type_members(value: Value): seq[Value] =
  if value.kind == VkGene and value.gene != nil and is_union_type_gene(value.gene):
    let gene = value.gene
    if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
      return gene.children

    result.add(gene.`type`)
    var i = 0
    while i < gene.children.len:
      let child = gene.children[i]
      if child.kind == VkSymbol and child.str == "|":
        if i + 1 < gene.children.len:
          result.add(gene.children[i + 1])
        i += 2
      else:
        i.inc()
    return result

  @[value]

proc looks_like_runtime_type_expr(self: Compiler, value: Value, depth = 0): bool =
  if depth > 64:
    return false

  case value.kind
  of VkSymbol, VkString, VkComplexSymbol:
    return self.likely_runtime_type_leaf(value)
  of VkGene:
    if value.gene == nil or value.gene.props.len > 0:
      return false
    let gene = value.gene

    if is_union_type_gene(gene):
      for member in union_type_members(value):
        if not self.looks_like_runtime_type_expr(member, depth + 1):
          return false
      return true

    if gene.`type`.kind == VkSymbol and gene.`type`.str == "Fn":
      if gene.children.len > 0 and gene.children[0].kind == VkArray:
        let items = array_data(gene.children[0])
        var i = 0
        while i < items.len:
          let item = items[i]
          if item.kind == VkSymbol and item.str.startsWith("^"):
            i.inc()
            if i < items.len and not self.looks_like_runtime_type_expr(items[i], depth + 1):
              return false
            i.inc()
            continue
          if not self.looks_like_runtime_type_expr(item, depth + 1):
            return false
          i.inc()
      if gene.children.len > 1 and not self.looks_like_runtime_type_expr(gene.children[1], depth + 1):
        return false
      return true

    if not self.likely_runtime_type_head(gene.`type`):
      return false
    for child in gene.children:
      if not self.looks_like_runtime_type_expr(child, depth + 1):
        return false
    true
  else:
    false

proc emit_type_local_binding(self: Compiler, name: string) =
  let reserved = self.reserve_local_binding(name)
  self.add_scope_start()
  self.emit(Instruction(kind: IkVar, arg0: reserved.index.to_value()))
  if not reserved.new_binding:
    self.scope_tracker.next_index = reserved.old_next_index
  if self.declared_names.len > 0:
    self.declared_names[^1][reserved.key] = true

proc compile_runtime_type_expr(self: Compiler, input: Value): bool =
  if input.kind != VkGene:
    return false
  if not self.looks_like_runtime_type_expr(input):
    return false
  let type_id = resolve_type_value_to_id(input, self.output.type_descriptors,
    self.output.type_aliases, self.output.module_path)
  self.emit(Instruction(kind: IkPushTypeValue, arg0: type_id.to_value()))
  true

proc compile_type_alias(self: Compiler, gene: ptr Gene) =
  if gene.children.len < 2 or gene.children[0].kind != VkSymbol:
    self.emit(Instruction(kind: IkPushNil))
    return

  let alias_name = gene.children[0].str
  let type_id = resolve_type_value_to_id(gene.children[1], self.output.type_descriptors,
    self.output.type_aliases, self.output.module_path)
  self.output.type_aliases[alias_name] = type_id
  self.emit(Instruction(kind: IkPushTypeValue, arg0: type_id.to_value()))

  if self.local_definitions:
    self.emit(Instruction(kind: IkNamespaceStore, arg0: alias_name.to_symbol_value()))

  self.emit_type_local_binding(alias_name)

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
  var method_prefix_args: seq[Value] = @[]

  proc parse_method_symbol(node: Value): tuple[name: string, args: seq[Value]] =
    case node.kind
    of VkSymbol:
      if not node.str.starts_with("."):
        not_allowed("Method symbol must start with '.'")
      let raw = node.str[1..^1]
      if raw.startsWith("@"):
        result.name = "@"
        let first_segment = raw[1..^1]
        if first_segment.len > 0:
          result.args.add(selector_segment_from_part(first_segment))
      else:
        result.name = raw
    of VkComplexSymbol:
      let parts = node.ref.csymbol
      if parts.len == 0 or not parts[0].starts_with("."):
        not_allowed("Method symbol must start with '.'")
      let raw = parts[0][1..^1]
      if not raw.startsWith("@"):
        not_allowed("Complex dotted method symbols are only supported for selector @ paths")
      result.name = "@"
      let first_segment = raw[1..^1]
      if first_segment.len > 0:
        result.args.add(selector_segment_from_part(first_segment))
      for part in parts[1..^1]:
        result.args.add(selector_segment_from_part(part))
    else:
      not_allowed("Invalid method symbol type: " & $node.kind)

  if gene.type.kind == VkSymbol and gene.type.str.starts_with("."):
    # (.method_name args...) - self is implicit
    let parsed = parse_method_symbol(gene.type)
    method_name = parsed.name
    method_prefix_args = parsed.args
    method_value = method_name.to_symbol_value()
    self.emit(Instruction(kind: IkSelf))
  elif gene.type.kind == VkComplexSymbol and gene.type.ref.csymbol.len > 0 and
      gene.type.ref.csymbol[0].starts_with("."):
    # (.@path/... args...) - self is implicit selector method shorthand
    let parsed = parse_method_symbol(gene.type)
    method_name = parsed.name
    method_prefix_args = parsed.args
    method_value = method_name.to_symbol_value()
    self.emit(Instruction(kind: IkSelf))
  else:
    # (obj .method_name args...) - obj is explicit
    self.compile(gene.type)
    let parsed = parse_method_symbol(gene.children[0])
    method_name = parsed.name
    method_prefix_args = parsed.args
    method_value = method_name.to_symbol_value()
    start_index = 1  # Skip the method name when adding arguments

  let arg_count = method_prefix_args.len + (gene.children.len - start_index)
  if method_name.ends_with("!"):
    not_allowed("Macro-like class methods are not supported; use (method name [args] ...) and a standalone fn! if you need quoted arguments")

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

    self.emit(Instruction(kind: IkNoop, label: fn_label))
    self.emit(Instruction(kind: IkSwap))
    self.emit(Instruction(kind: IkGeneAddChild))
    for arg in method_prefix_args:
      self.emit(Instruction(kind: IkPushValue, arg0: arg))
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
    for arg in method_prefix_args:
      self.emit(Instruction(kind: IkPushValue, arg0: arg))
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
  for k, v in gene.props:
    self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](k)))
    self.compile(v)

  for arg in method_prefix_args:
    self.emit(Instruction(kind: IkPushValue, arg0: arg))

  for i in start_index..<gene.children.len:
    self.compile(gene.children[i])

  let kw_count = gene.props.len
  let total_items = arg_count + kw_count * 2
  if kw_count > 0xFFFF or total_items > 0xFFFF:
    not_allowed("Too many keyword arguments for unified method call")
  let packed = ((total_items shl 16) or kw_count).int32
  self.emit(Instruction(kind: IkUnifiedMethodCallKw, arg0: method_value, arg1: packed))
  return

## compile_vm moved to compiler/misc.nim

proc normalized_infix_operator(op_value: Value): string {.inline.} =
  ## Normalize parser-specific infix operator values.
  case op_value.kind
  of VkSymbol:
    let op = op_value.str
    if op in ["+", "-", "*", "/", "%", "**", "++", "./", "<", "<=", ">", ">=", "==", "!=", "is", "&&", "||", "&|&", "<<", ">>"]:
      return op
  of VkComplexSymbol:
    # Parser variant: "./" can be emitted as complex symbol @[".", ""]
    if op_value.ref.csymbol.len >= 2 and op_value.ref.csymbol[0] == "." and op_value.ref.csymbol[1] == "":
      return "./"
  else:
    discard
  ""

proc infix_precedence(op: string): int {.inline.} =
  case op
  of "./":
    90
  of "*", "/", "%", "**":
    80
  of "+", "-", "++":
    70
  of "<<", ">>":
    65
  of "<", "<=", ">", ">=", "==", "!=", "is":
    60
  of "&&":
    50
  of "&|&":
    45
  of "||":
    40
  else:
    0

proc is_infix_rewrite_eligible(expr_type: Value): bool {.inline.} =
  ## Skip infix desugaring when the leading value is a special-form symbol.
  if expr_type.kind != VkSymbol:
    return true
  expr_type.str notin [
    "var", "if", "ifel", "fn", "do", "loop", "while", "for", "ns", "class",
    "try", "throw", "import", "export", "interface", "implement", "field", "$", "$vm", "$vmstmt", ".", "->", "@"
  ]

proc rewrite_infix_expression(left_value: Value, tail: seq[Value]): Value =
  ## Convert infix chains to nested prefix genes using precedence + left associativity.
  ## Example: [1, +, 2, *, 3] => (+ 1 (* 2 3))
  if tail.len mod 2 != 0:
    not_allowed("Incomplete infix expression")

  var value_stack: seq[Value] = @[left_value]
  var op_stack: seq[string] = @[]

  proc reduce_once() =
    if op_stack.len == 0 or value_stack.len < 2:
      not_allowed("Invalid infix expression")
    let op = op_stack.pop()
    let rhs = value_stack.pop()
    let lhs = value_stack.pop()
    let node = new_gene(op.to_symbol_value())
    node.children = @[lhs, rhs]
    value_stack.add(node.to_gene_value())

  var i = 0
  while i < tail.len:
    let op = normalized_infix_operator(tail[i])
    if op.len == 0:
      not_allowed("Invalid infix expression")

    while op_stack.len > 0 and infix_precedence(op_stack[^1]) >= infix_precedence(op):
      reduce_once()

    op_stack.add(op)
    value_stack.add(tail[i + 1])
    i += 2

  while op_stack.len > 0:
    reduce_once()

  if value_stack.len != 1:
    not_allowed("Invalid infix expression")
  value_stack[0]

proc compile_gene(self: Compiler, input: Value) =
  let gene = input.gene
  
  # Special case: handle selector operator ./
  if not gene.type.is_nil():
    if DEBUG:
      compiler_log(LlDebug, "compile_gene: gene.type.kind = " & $gene.type.kind)
      if gene.type.kind == VkSymbol:
        compiler_log(LlDebug, "compile_gene: gene.type.str = '" & gene.type.str & "'")
      elif gene.type.kind == VkComplexSymbol:
        compiler_log(LlDebug, "compile_gene: gene.type.csymbol = " & $gene.type.ref.csymbol)
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
  
  # Special case: super calls use dedicated super-call instructions.
  if gene.type.kind == VkSymbol and gene.type.str == "super":
    if gene.children.len == 0:
      not_allowed("super requires a member")
    let member = gene.children[0]
    if member.kind != VkSymbol:
      not_allowed("super requires a method or constructor symbol (e.g., .m or .ctor)")
    if member.str == "ctor" or member.str == "ctor!":
      not_allowed("super constructor calls must use .ctor")
    if not member.str.starts_with("."):
      not_allowed("super requires a method or constructor symbol (e.g., .m or .ctor)")
    let member_str = member.str
    let member_name = member_str[1..^1]  # strip leading dot
    if member_name.ends_with("!"):
      if member_str == ".ctor!":
        not_allowed("Macro-like super constructors are not supported; use .ctor")
      not_allowed("Macro-like super methods are not supported; use a regular method and a standalone fn! if you need quoted arguments")
    let is_ctor = member_str == ".ctor"
    let arg_start = 1
    let arg_count = gene.children.len - arg_start

    if gene.props.len == 0:
      let old_tail = self.tail_position
      self.tail_position = false
      for i in arg_start..<gene.children.len:
        self.compile(gene.children[i])
      self.tail_position = old_tail

      let inst_kind =
        if is_ctor:
          IkCallSuperCtor
        else:
          IkCallSuperMethod

      self.emit(
        Instruction(
          kind: inst_kind,
          arg0: member_name.to_symbol_value(),
          arg1: arg_count.int32,
        )
      )
    else:
      # Keyword super-call layout mirrors IkUnifiedMethodCallKw:
      # [kw_key1, kw_val1, ..., kw_keyN, kw_valN, pos_arg1, ..., pos_argM]
      for k, v in gene.props:
        self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](k)))
        self.compile(v)

      for i in arg_start..<gene.children.len:
        self.compile(gene.children[i])

      let kw_count = gene.props.len
      let total_items = arg_count + kw_count * 2
      if kw_count > 0xFFFF or total_items > 0xFFFF:
        not_allowed("Too many keyword arguments for super call")
      let packed = ((total_items shl 16) or kw_count).int32
      let inst_kind = if is_ctor: IkCallSuperCtorKw else: IkCallSuperMethodKw
      self.emit(Instruction(kind: inst_kind, arg0: member_name.to_symbol_value(), arg1: packed))
    return

  let is_quoted_symbol_method_call = gene.type.kind == VkQuote and gene.type.ref.quote.kind == VkSymbol and
    gene.children.len >= 1 and gene.children[0].kind == VkSymbol and gene.children[0].str.starts_with(".")

  if self.quote_level > 0 or gene.frozen or gene.type == "_".to_symbol_value() or
     (gene.type.kind == VkQuote and not is_quoted_symbol_method_call):
    self.compile_gene_default(gene)
    return

  let `type` = gene.type

    
  # Check for infix notation: (value operator args...)
  # This handles cases like (6 / 2) or (i + 1)
  if gene.children.len >= 1:
    let first_child = gene.children[0]
    let infix_op = normalized_infix_operator(first_child)
    if infix_op.len > 0:
      if is_infix_rewrite_eligible(`type`):
        self.compile(rewrite_infix_expression(`type`, gene.children))
        return
    elif first_child.kind == VkSymbol:
      if first_child.str == ".":
        # Dynamic method call: (obj . method_expr args...)
        # Compile: obj on stack, evaluate method_expr to get method name, then call
        self.compile_dynamic_method_call(gene)
        return
      elif first_child.str.starts_with("."):
        # This is a method call: (obj .method args...)
        # Transform to method call format
        self.compile_method_call(gene)
        return
    elif first_child.kind == VkComplexSymbol and first_child.ref.csymbol.len > 0 and
        first_child.ref.csymbol[0].starts_with(".@"):
      # Selector method shorthand: (obj .@path/... [args...])
      self.compile_method_call(gene)
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
      of "%":
        if gene.children.len == 0:
          not_allowed("% requires at least one argument")
        elif gene.children.len == 1:
          not_allowed("% requires at least 2 arguments")
        elif gene.children.len == 2:
          if self.compile_var_op_literal(gene.children[0], gene.children[1], IkVarModValue):
            return
          # Fall through to regular compilation
        # Multi-arg modulo
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkMod))
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
      of "is":
        # Type check: (x is Int)
        if gene.children.len != 2:
          not_allowed("is requires exactly 2 arguments: (value is Type)")
        self.compile(gene.children[0])
        # children[1] is the type name — compile it as an expression so it
        # resolves to the class value at runtime (supports user classes)
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkIsType))
        return
      of "<<":
        if gene.children.len != 2:
          not_allowed("<< requires exactly 2 arguments")
        self.compile(gene.children[0])
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkShl))
        return
      of ">>":
        if gene.children.len != 2:
          not_allowed(">> requires exactly 2 arguments")
        self.compile(gene.children[0])
        self.compile(gene.children[1])
        self.emit(Instruction(kind: IkShr))
        return
      of "&&":
        if gene.children.len == 0:
          not_allowed("&& requires at least one argument")
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkAnd))
        return
      of "&|&":
        if gene.children.len == 0:
          not_allowed("&|& requires at least one argument")
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkXor))
        return
      of "||":
        if gene.children.len == 0:
          not_allowed("|| requires at least one argument")
        self.compile(gene.children[0])
        for i in 1..<gene.children.len:
          self.compile(gene.children[i])
          self.emit(Instruction(kind: IkOr))
        return
      else:
        discard  # Not an arithmetic operator, continue with normal processing
  
  if gene.children.len > 0:
    let first = gene.children[0]
    if first.kind == VkSymbol:
      case first.str:
        of "=", "+=", "-=", "*=", "/=", "%=":
          self.compile_assignment(gene)
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
      of "ifel":
        self.compile_ifel(gene)
        return
      of "if_not":
        self.compile_if_not(gene)
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
      of "not", "!":
        if gene.children.len != 1:
          let trace = self.current_trace()
          if trace != nil:
            compiler_log(LlWarn, "not arity (type): " & trace_location(trace))
          else:
            compiler_log(LlWarn, "not arity (type): <no-trace>")
          not_allowed("not expects exactly 1 argument")
        self.compile_unary_not(gene.children[0])
        return
      of "typeof":
        if gene.children.len != 1:
          not_allowed("typeof expects exactly 1 argument")
        self.compile(gene.children[0])
        self.emit(Instruction(kind: IkTypeOf))
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
        self.compile_interface(gene)
        return
      of "implement":
        self.compile_implement(gene)
        return
      of "field":
        self.compile_field_definition(gene)
        return
      of "type":
        self.compile_type_alias(gene)
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
        let location = trace_location(gene.trace)
        let message = "match has been removed; use (var pattern value) for binding or (case ...) for branching"
        if location.len > 0:
          not_allowed(location & ": " & message)
        else:
          not_allowed(message)
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
      of "on_method_missing":
        self.compile_on_method_missing_definition(gene)
        return
      of "method!":
        not_allowed("Macro-like class methods are not supported; use (method name [args] ...)")
      of "ctor", "ctor!":
        # Constructor definition inside class body
        self.compile_constructor_definition(gene)
        return
      of "prop":
        # Property definition inside class body
        self.compile_prop_definition(gene)
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
            of "$dep":
              if gene.children.len < 1:
                not_allowed("$dep requires package name")
              let dep_name_val = gene.children[0]
              if dep_name_val.kind notin {VkString, VkSymbol}:
                not_allowed("$dep package name must be a string or symbol")

              var dep_path = ""
              if "path".to_key() in gene.props:
                let path_val = gene.props["path".to_key()]
                if path_val.kind in {VkString, VkSymbol}:
                  dep_path = path_val.str
              if dep_path.len == 0 and gene.children.len > 1 and gene.children[1].kind in {VkString, VkSymbol}:
                dep_path = gene.children[1].str
              if dep_path.len == 0:
                not_allowed("$dep requires ^path <string>")

              if App != NIL and App.kind == VkApplication and App.app.global_ns.kind == VkNamespace:
                let deps_key = "__deps__".to_key()
                var deps_registry = App.app.global_ns.ref.ns.members.getOrDefault(deps_key, NIL)
                if deps_registry == NIL or deps_registry.kind != VkMap:
                  deps_registry = new_map_value()
                  App.app.global_ns.ref.ns.members[deps_key] = deps_registry
                  if App.app.gene_ns.kind == VkNamespace:
                    App.app.gene_ns.ref.ns.members[deps_key] = deps_registry
                let dep_entry = new_map_value()
                map_data(dep_entry)["path".to_key()] = dep_path.to_value()
                map_data(deps_registry)[dep_name_val.str.to_key()] = dep_entry

              self.emit(Instruction(kind: IkPushNil))
              return

  if self.compile_runtime_type_expr(input):
    return

  self.compile_gene_unknown(gene)
