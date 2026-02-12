## Function, class, and method compilation:
## compile_fn, compile_return, compile_block, compile_ns,
## compile_method_definition, compile_constructor_definition,
## compile_class_with_container, compile_class, compile_object,
## compile_new, compile_super, compile_match.
## Included from compiler.nim — shares its scope.

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
    let compiled = compile_init(body, local_defs = true, module_path = self.output.module_path)
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

proc compile_prop_definition(self: Compiler, gene: ptr Gene) =
  ## Compile property definition: (prop x) or (prop x: Type)
  if gene.children.len == 0:
    not_allowed("prop requires a name")
  var name_val = gene.children[0]
  var type_id: TypeId = NO_TYPE_ID
  if name_val.kind == VkSymbol and name_val.str.ends_with(":"):
    # (prop x: Int) — name_val is "x:", children[1] is "Int"
    let base_name = name_val.str[0..^2]
    if gene.children.len > 1:
      type_id = resolve_type_value_to_id(gene.children[1], self.output.type_descriptors, self.output.type_aliases, self.output.module_path)
    self.emit(Instruction(kind: IkDefineProp, arg0: base_name.to_key().to_value(), arg1: type_id))
  else:
    # (prop x) — untyped property declaration
    if name_val.kind != VkSymbol:
      not_allowed("prop name must be a symbol")
    self.emit(Instruction(kind: IkDefineProp, arg0: name_val.str.to_key().to_value(), arg1: NO_TYPE_ID))

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
  if gene.children.len > body_start:
    let body = new_stream_value(gene.children[body_start..^1])
    let compiled = compile_init(body, local_defs = true, module_path = self.output.module_path)
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
