## Interface and Adapter compilation:
## compile_interface, compile_implement, compile_adapter_call.
## Included from compiler.nim — shares its scope.

proc interface_prop_name(input: Value): string =
  if input.kind notin {VkSymbol, VkString}:
    not_allowed("property name must be a symbol or string")
  result = input.str
  if result.ends_with(":"):
    result = result[0..^2]

proc compile_interface_method_decl(self: Compiler, gene: ptr Gene) =
  if gene.children.len == 0:
    not_allowed("interface method requires a name")

  let name = gene.children[0]
  if name.kind notin {VkSymbol, VkString}:
    not_allowed("interface method name must be a symbol or string")

  self.emit(Instruction(kind: IkInterfaceMethod, arg0: name))

proc compile_interface_prop_decl(self: Compiler, gene: ptr Gene) =
  if gene.children.len == 0:
    not_allowed("interface prop requires a name")

  let prop_name = interface_prop_name(gene.children[0])
  let readonly =
    gene.props.has_key("readonly".to_key()) and
    gene.props["readonly".to_key()] notin [FALSE, NIL]

  self.emit(
    Instruction(
      kind: IkInterfaceProp,
      arg0: prop_name.to_value(),
      arg1: (if readonly: 1 else: 0).int32,
    )
  )

proc compile_external_implement_method(self: Compiler, gene: ptr Gene) =
  if gene.children.len < 2:
    not_allowed("method requires a name and argument list")

  let name = gene.children[0]
  if name.kind != VkSymbol:
    not_allowed("method name must be a symbol")

  let parsed_name = split_generic_definition_name(name.str)
  let method_name = parsed_name.base_name.to_symbol_value()
  if method_name.kind notin {VkString, VkSymbol}:
    not_allowed("method name must be a symbol or string")

  var fn_value = new_gene_value()
  fn_value.gene.type = "fn".to_symbol_value()
  for k, v in gene.props:
    fn_value.gene.props[k] = v

  # Preserve the original method name on the lowered function so generic method
  # parameters continue to be visible to to_function(), but register the stripped
  # base name on the implementation mapping.
  fn_value.gene.children.add(name)

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
    method_args = new_array_value()
    array_data(method_args).add("self".to_symbol_value())
  elif args.kind == VkSymbol and args.str == "self":
    method_args = new_array_value()
    array_data(method_args).add(args)
  else:
    method_args = new_array_value()
    array_data(method_args).add("self".to_symbol_value())
    array_data(method_args).add(args)

  fn_value.gene.children.add(method_args)

  if gene.children.len == 2:
    fn_value.gene.children.add(NIL)
  else:
    for i in 2..<gene.children.len:
      fn_value.gene.children.add(gene.children[i])

  self.compile_fn(fn_value, define_binding = false)
  self.emit(Instruction(kind: IkImplementMethod, arg0: method_name))

proc compile_interface*(self: Compiler, gene: ptr Gene) =
  ## Compile an interface definition
  ## Syntax: (interface Name body...)
  
  if gene.children.len == 0:
    not_allowed("interface requires a name")
  
  let name = gene.children[0]
  if name.kind != VkSymbol:
    not_allowed("interface name must be a symbol")
  
  # Emit the interface instruction
  self.emit(Instruction(kind: IkInterface, arg0: name))

  for i in 1..<gene.children.len:
    let child = gene.children[i]
    if child.kind != VkGene or child.gene == nil or child.gene.type.kind != VkSymbol:
      not_allowed("interface body only supports method and prop declarations")
    case child.gene.type.str
    of "method":
      self.compile_interface_method_decl(child.gene)
    of "prop":
      self.compile_interface_prop_decl(child.gene)
    else:
      not_allowed("unsupported interface member: " & child.gene.type.str)

proc compile_implement*(self: Compiler, gene: ptr Gene) =
  ## Compile an implement block
  ## Two forms:
  ## 1. Inline (inside class): (implement InterfaceName body...)
  ## 2. External: (implement InterfaceName for ClassName body...)
  
  if gene.children.len == 0:
    not_allowed("implement requires at least an interface name")
  
  let interface_name = gene.children[0]
  if interface_name.kind != VkSymbol:
    not_allowed("interface name must be a symbol")
  
  var target_class: Value = NIL
  var body_start = 1
  var is_external = false
  
  # Check for "for" keyword: (implement Interface for Class body...)
  if gene.children.len >= 3 and gene.children[1].kind == VkSymbol and gene.children[1].str == "for":
    target_class = gene.children[2]
    body_start = 3
    is_external = true
  let has_body = gene.children.len > body_start
  
  # Emit the implement instruction
  # arg0 = interface name
  # arg1 bit 0 = external, bit 1 = has body
  # If external, target_class is compiled before the instruction
  let flags = ((if is_external: 1 else: 0) or (if has_body: 2 else: 0)).int32
  if is_external:
    self.compile(target_class)
    self.emit(Instruction(kind: IkImplement, arg0: interface_name, arg1: flags))
  else:
    self.emit(Instruction(kind: IkImplement, arg0: interface_name, arg1: flags))
  
  # If there's a body, compile it
  if has_body:
    if is_external:
      for i in body_start..<gene.children.len:
        let child = gene.children[i]
        if child.kind != VkGene or child.gene == nil or child.gene.type.kind != VkSymbol:
          not_allowed("external implement body only supports method declarations")
        case child.gene.type.str
        of "method":
          self.compile_external_implement_method(child.gene)
        else:
          not_allowed("unsupported external implement member: " & child.gene.type.str)
      self.emit(Instruction(kind: IkPop))
      self.emit(Instruction(kind: IkPushNil))
    else:
      let body = new_stream_value(gene.children[body_start..^1])
      let compiled = compile_init(body,
        local_defs = true,
        module_path = self.output.module_path,
        inherited_type_descriptors = self.output.type_descriptors,
        inherited_type_aliases = self.output.type_aliases)
      let r = new_ref(VkCompiledUnit)
      r.cu = compiled
      self.emit(Instruction(kind: IkPushValue, arg0: r.to_ref_value()))
      self.emit(Instruction(kind: IkCallInit))

proc compile_adapter_call*(self: Compiler, gene: ptr Gene) =
  ## Compile an interface call that creates an adapter
  ## Syntax: (InterfaceName obj)
  ## 
  ## This is called when InterfaceName is used as a function call
  ## on an object that doesn't have an inline implementation.
  
  # The type (interface) is already compiled and on the stack
  # Compile the argument (the object to wrap)
  if gene.children.len == 0:
    not_allowed("adapter call requires an object to wrap")
  
  self.compile(gene.children[0])
  
  # Emit adapter instruction
  self.emit(Instruction(kind: IkAdapter))
