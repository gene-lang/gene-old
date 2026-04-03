## Function, class, and method compilation:
## compile_fn, compile_return, compile_block, compile_ns,
## compile_method_definition, compile_constructor_definition,
## compile_class_with_container, compile_class, compile_object,
## compile_new, compile_super.
## Included from compiler.nim — shares its scope.

proc mark_local_fn(input: Value) =
  if input.kind == VkGene and input.gene != nil:
    input.gene.props[local_def_key()] = TRUE

const
  CONTRACTS_ENABLED_FN = "__contracts_enabled__"
  CONTRACT_VIOLATION_FN = "__contract_violation__"

proc contract_call_expr(name: string, args: openArray[Value]): Value =
  result = new_gene_value()
  result.gene.type = name.to_symbol_value()
  for arg in args:
    result.gene.children.add(arg)

proc contract_condition_text(condition: Value): string =
  $condition

proc compile_contract_violation(self: Compiler, phase: string, function_name: string,
                                condition_index: int, condition_text: string,
                                include_result: bool) =
  var args: seq[Value] = @[
    phase.to_value(),
    function_name.to_value(),
    condition_index.to_value(),
    condition_text.to_value(),
  ]
  if include_result:
    args.add("result".to_symbol_value())
  self.compile(contract_call_expr(CONTRACT_VIOLATION_FN, args))
  self.emit(Instruction(kind: IkPop))

proc compile_contract_check(self: Compiler, condition: Value, phase: string,
                            function_name: string, condition_index: int,
                            include_result = false) =
  let skip_label = new_label()
  let fail_label = new_label()

  self.compile(contract_call_expr(CONTRACTS_ENABLED_FN, @[]))
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: skip_label.to_value()))

  self.compile(condition)
  self.emit(Instruction(kind: IkJumpIfFalse, arg0: fail_label.to_value()))
  self.emit(Instruction(kind: IkJump, arg0: skip_label.to_value()))

  self.emit(Instruction(kind: IkNoop, label: fail_label))
  self.compile_contract_violation(
    phase,
    function_name,
    condition_index,
    contract_condition_text(condition),
    include_result
  )
  self.emit(Instruction(kind: IkNoop, label: skip_label))

proc emit_post_contract_checks(self: Compiler) =
  if self.contract_post_conditions.len == 0:
    return
  if self.contract_result_slot < 0:
    return

  # Keep the original return value on stack while also binding it to `result`.
  self.emit(Instruction(kind: IkDup))
  self.add_scope_start()
  self.emit(Instruction(kind: IkVar, arg0: self.contract_result_slot.to_value()))
  self.emit(Instruction(kind: IkPop))

  let result_key = "result".to_key()
  let had_result_mapping = self.scope_tracker.mappings.has_key(result_key)
  var old_result_index: int16 = 0
  if had_result_mapping:
    old_result_index = self.scope_tracker.mappings[result_key]
  self.scope_tracker.mappings[result_key] = self.contract_result_slot

  for i, condition in self.contract_post_conditions:
    self.compile_contract_check(condition, "post", self.contract_fn_name, i + 1, include_result = true)

  if had_result_mapping:
    self.scope_tracker.mappings[result_key] = old_result_index
  else:
    self.scope_tracker.mappings.del(result_key)

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
  var binding_type_id: TypeId = NO_TYPE_ID

  if self.output.type_registry == nil:
    self.output.type_registry = populate_registry(self.output.type_descriptors, self.output.module_path)

  var fn_obj = to_function(input, self.output.type_descriptors, self.output.type_aliases,
    self.output.module_path, self.output.type_registry)
  var type_expectation_ids: seq[TypeId] = @[]
  if fn_obj.matcher != nil:
    type_expectation_ids = newSeq[TypeId](fn_obj.matcher.children.len)
    for i, child in fn_obj.matcher.children:
      type_expectation_ids[i] = child.type_id

  var compiled_body: CompilationUnit = nil
  if self.eager_functions:
    fn_obj.scope_tracker = tracker_copy
    compile(fn_obj, true)
    compiled_body = fn_obj.body_compiled

  let info = new_function_def_info(tracker_copy, compiled_body, input,
    type_expectation_ids, if fn_obj.matcher != nil: fn_obj.matcher.return_type_id else: NO_TYPE_ID)
  self.emit(Instruction(kind: IkFunction, arg0: info.to_value()))

  if local_binding:
    self.add_scope_start()
    set_expected_type_id(self.scope_tracker, local_index, binding_type_id)
    self.emit(Instruction(kind: IkVar, arg0: local_index.to_value(), arg1: binding_type_id))
    if not local_new_binding:
      self.scope_tracker.next_index = local_old_next
    if self.declared_names.len > 0:
      self.declared_names[^1][local_key] = true

proc compile_return(self: Compiler, gene: ptr Gene) =
  if gene.children.len > 0:
    self.compile(gene.children[0])
  else:
    self.emit(Instruction(kind: IkPushNil))
  self.emit_post_contract_checks()
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
    let compiled = compile_init(body,
      local_defs = true,
      module_path = self.output.module_path,
      inherited_type_descriptors = self.output.type_descriptors,
      inherited_type_aliases = self.output.type_aliases)
    let r = new_ref(VkCompiledUnit)
    r.cu = compiled
    self.emit(Instruction(kind: IkPushValue, arg0: r.to_ref_value()))
    self.emit(Instruction(kind: IkCallInit))

proc compile_method_definition(self: Compiler, gene: ptr Gene) =
  # Method definition: (method name [args] body...)
  if gene.children.len < 2:
    not_allowed("Method definition requires at least name and args")
  
  let name = gene.children[0]
  if name.kind != VkSymbol:
    not_allowed("Method name must be a symbol")
  let parsed_name = split_generic_definition_name(name.str)
  if parsed_name.base_name.ends_with("!"):
    not_allowed("Macro-like class methods are not supported; use (method name [args] ...) and a standalone fn! if you need quoted arguments")
  let method_name = parsed_name.base_name.to_symbol_value()
  
  # Create a function from the method definition
  # The method is similar to (fn name [args] body...) but bound to the class
  var fn_value = new_gene_value()
  fn_value.gene.type = "fn".to_symbol_value()
  for k, v in gene.props:
    fn_value.gene.props[k] = v

  # Preserve generic method parameters on the lowered function name so
  # to_function can intern TdkVar descriptors. The runtime-visible method
  # name is still the stripped base name via IkDefineMethod.
  fn_value.gene.children.add(name)
  
  let args = gene.children[1]
  if args.kind != VkArray:
    not_allowed("method requires an array argument list; use [] for no arguments")

  var method_args = new_array_value()
  let src = array_data(args)
  if src.len == 0:
    array_data(method_args).add("self".to_symbol_value())
  elif src[0].kind == VkSymbol and src[0].str == "self":
    for arg in src:
      array_data(method_args).add(arg)
  else:
    array_data(method_args).add("self".to_symbol_value())
    for arg in src:
      array_data(method_args).add(arg)
  
  fn_value.gene.children.add(method_args)

  var body_start = 2
  if gene.children.len > body_start and gene.children[body_start].kind == VkSymbol and gene.children[body_start].str == "->":
    if gene.children.len <= body_start + 1:
      not_allowed("Missing return type after ->")
    body_start += 2
  if gene.children.len > body_start and gene.children[body_start].kind == VkSymbol and gene.children[body_start].str == "!":
    if gene.children.len <= body_start + 1:
      not_allowed("Missing effects list after !")
    body_start += 2

  if body_start >= gene.children.len:
    return

  # Add the body
  for i in 2..<gene.children.len:
    fn_value.gene.children.add(gene.children[i])
  
  # Compile the function definition
  self.compile_fn(fn_value, define_binding = false)
  
  # Add the method to the class
  self.emit(Instruction(kind: IkDefineMethod, arg0: method_name))

proc compile_on_method_missing_definition(self: Compiler, gene: ptr Gene) =
  if gene.children.len < 1:
    not_allowed("on_method_missing requires an argument list")

  var method_gene = new_gene("method".to_symbol_value())
  for k, v in gene.props:
    method_gene.props[k] = v
  method_gene.children.add("on_method_missing".to_symbol_value())
  for child in gene.children:
    method_gene.children.add(child)
  self.compile_method_definition(method_gene)

proc compile_constructor_definition(self: Compiler, gene: ptr Gene) =
  if gene.type.kind == VkSymbol and gene.type.str == "ctor!":
    not_allowed("Macro-like constructors are not supported; use (ctor [args] ...)")
  if gene.children.len == 0:
    not_allowed(gene.type.str & " requires an array argument list; use [] for no arguments")

  # Create a function from the constructor definition
  # The constructor is similar to (fn new [args] body...) but bound to the class
  var fn_value = new_gene_value()
  fn_value.gene.type = "fn".to_symbol_value()
  for k, v in gene.props:
    fn_value.gene.props[k] = v
  fn_value.gene.children.add(gene.type.str.to_symbol_value())
  
  let args = gene.children[0]
  if args.kind != VkArray:
    not_allowed(gene.type.str & " requires an array argument list; use [] for no arguments")
  let args_array = args
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

proc compile_prop_definition(self: Compiler, gene: ptr Gene) =
  ## Compile property definition: (field x) or (field x: Type)
  if gene.children.len == 0:
    not_allowed("prop requires a name")
  var name_val = gene.children[0]
  var type_id: TypeId = NO_TYPE_ID
  if name_val.kind == VkSymbol and name_val.str.ends_with(":"):
    # (field x: Int) — name_val is "x:", children[1] is "Int"
    let base_name = name_val.str[0..^2]
    if gene.children.len > 1:
      type_id = resolve_type_value_to_id(gene.children[1], self.output.type_descriptors, self.output.type_aliases, self.output.module_path)
    self.emit(Instruction(kind: IkDefineProp, arg0: base_name.to_key().to_value(), arg1: type_id))
  else:
    # (field x) — untyped property declaration
    if name_val.kind != VkSymbol:
      not_allowed("prop name must be a symbol")
    self.emit(Instruction(kind: IkDefineProp, arg0: name_val.str.to_key().to_value(), arg1: NO_TYPE_ID))

proc compile_field_definition(self: Compiler, gene: ptr Gene) =
  ## Compile field definition: (field name Type)
  if gene.children.len == 0:
    not_allowed("field requires a name and type")
  let name_val = gene.children[0]
  if name_val.kind != VkSymbol:
    not_allowed("field name must be a symbol")
  var field_name = name_val.str
  if field_name.ends_with(":"):
    field_name = field_name[0..^2]
  let type_id =
    if gene.children.len > 1:
      resolve_type_value_to_id(gene.children[1], self.output.type_descriptors, self.output.type_aliases, self.output.module_path)
    else:
      NO_TYPE_ID
  self.emit(Instruction(kind: IkDefineProp, arg0: field_name.to_key().to_value(), arg1: type_id))

proc parse_class_header(gene: ptr Gene): tuple[parent_class: Value, interfaces: seq[Value], body_start: int] =
  result.parent_class = NIL
  result.body_start = 1
  while result.body_start < gene.children.len:
    let child = gene.children[result.body_start]
    if child.kind == VkSymbol and child.str == "<":
      if result.body_start + 1 >= gene.children.len:
        not_allowed("Missing superclass after <")
      result.parent_class = gene.children[result.body_start + 1]
      result.body_start += 2
      continue
    if child.kind == VkSymbol and child.str == "implements":
      if result.body_start + 1 >= gene.children.len:
        not_allowed("Missing interface list after implements")
      let interfaces_val = gene.children[result.body_start + 1]
      case interfaces_val.kind
      of VkSymbol:
        result.interfaces.add(interfaces_val)
      of VkArray:
        for item in array_data(interfaces_val):
          if item.kind != VkSymbol:
            not_allowed("implements expects interface symbols")
          result.interfaces.add(item)
      else:
        not_allowed("implements expects an interface symbol or array of interface symbols")
      result.body_start += 2
      continue
    break

proc compile_class_with_container(self: Compiler, class_name: Value, parent_class: Value, implemented_interfaces: seq[Value], container_expr: Value, body_start: int, gene: ptr Gene) =
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

  # Register user class as a TypeDesc in the module's type registry
  if class_name.kind == VkSymbol:
    discard intern_type_desc(self.output.type_descriptors,
      TypeDesc(module_path: self.output.module_path, kind: TdkNamed, name: class_name.str))

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
  if gene.children.len > body_start or implemented_interfaces.len > 0:
    let body = new_stream_value()
    for iface in implemented_interfaces:
      var implement_gene = new_gene("implement".to_symbol_value())
      implement_gene.children.add(iface)
      body.ref.stream.add(implement_gene.to_gene_value())
    for i in body_start..<gene.children.len:
      let child = gene.children[i]
      if child.kind == VkGene and child.gene != nil and child.gene.`type`.kind == VkSymbol and child.gene.`type`.str == "implement":
        not_allowed("Classes must declare interfaces in the header with implements")
      body.ref.stream.add(gene.children[i])
    let compiled = compile_init(body,
      local_defs = true,
      module_path = self.output.module_path,
      inherited_type_descriptors = self.output.type_descriptors,
      inherited_type_aliases = self.output.type_aliases)
    let r = new_ref(VkCompiledUnit)
    r.cu = compiled
    self.emit(Instruction(kind: IkPushValue, arg0: r.to_ref_value()))
    self.emit(Instruction(kind: IkCallInit))

proc compile_class(self: Compiler, gene: ptr Gene) =
  apply_container_to_child(gene, 0)
  let container_expr = gene.props.getOrDefault(container_key(), NIL)
  let header = parse_class_header(gene)

  # Use helper function for actual compilation
  self.compile_class_with_container(gene.children[0], header.parent_class, header.interfaces, container_expr, header.body_start, gene)

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

  if gene.type.kind == VkSymbol and gene.type.str == "new!":
    not_allowed("Macro-like constructors are not supported; use (new Class ...)")

# Compile the class first, then the arguments
  # Stack will be: [class, args] so VM can pop args first, then class
  self.compile(gene.children[0])

  # Always create a Gene for arguments so the VM can process positional and
  # keyword arguments uniformly.
  if gene.children.len > 1 or gene.props.len > 0:
    self.emit(Instruction(kind: IkGeneStart))
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

  self.emit(Instruction(kind: IkNew))

proc compile_super(self: Compiler, gene: ptr Gene) =
  discard gene
  not_allowed("super can only be used in call form: (super .member ...)")
