## Function (to_function, new_fn) and Block (to_block, new_block).
## Included from core.nim — shares its scope.

#################### Function ####################

proc new_fn*(name: string, matcher: RootMatcher, body: sink seq[Value]): Function =
  return Function(
    name: name,
    matcher: matcher,
    # matching_hint: matcher.hint,
    body: body,
  )

proc anchor_module_paths(type_descs: var seq[TypeDesc], module_path: string) =
  ## Ensure non-builtin descriptors carry the parent module path.
  if module_path.len == 0:
    return
  for i in 0..<type_descs.len:
    var desc = type_descs[i]
    if desc.module_path.len > 0:
      continue
    var should_anchor = true
    if desc.kind == TdkNamed and lookup_builtin_type(desc.name) != NO_TYPE_ID:
      should_anchor = false
    if should_anchor:
      desc.module_path = module_path
      type_descs[i] = desc

proc register_type_descs(registry: ModuleTypeRegistry, type_descs: seq[TypeDesc], module_path: string) =
  ## Keep parent module registry in sync with descriptors used by nested functions.
  if registry == nil:
    return
  if registry.module_path.len == 0:
    registry.module_path = module_path
  for i, desc in type_descs:
    registry.descriptors[i.TypeId] = desc

proc to_function*(node: Value, cu_type_descs: var seq[TypeDesc],
                  type_aliases: Table[string, TypeId] = initTable[string, TypeId](),
                  module_path = "",
                  type_registry: ModuleTypeRegistry = nil): Function {.gcsafe.}

proc to_function*(node: Value): Function {.gcsafe.} =
  ## Create a Function from a Gene node, using a local type descriptor table.
  var local_descs = builtin_type_descs()
  var inferred_module_path = ""
  if node.kind == VkGene and node.gene != nil and node.gene.trace != nil:
    inferred_module_path = module_path_from_source(node.gene.trace.filename)
  return to_function(node, local_descs, module_path = inferred_module_path)

proc to_function*(node: Value, cu_type_descs: var seq[TypeDesc],
                  type_aliases: Table[string, TypeId] = initTable[string, TypeId](),
                  module_path = "",
                  type_registry: ModuleTypeRegistry = nil): Function {.gcsafe.} =
  if node.kind != VkGene:
    raise new_exception(type_defs.Exception, "Expected Gene for function definition, got " & $node.kind)

  if node.gene == nil:
    raise new_exception(type_defs.Exception, "Gene pointer is nil")

  # Intern types into the provided table (CU's or local).
  template type_descs: var seq[TypeDesc] = cu_type_descs
  let aliases = type_aliases

  # Extract type annotations as name -> TypeId mapping, and strip them from args
  proc strip_type_annotations(args: Value, type_id_map: var Table[string, TypeId],
                              type_descs: var seq[TypeDesc],
                              aliases: Table[string, TypeId]): Value =
    if args.kind != VkArray:
      return args
    let src = array_data(args)
    var out_args = new_array_value()
    var i = 0
    while i < src.len:
      let item = src[i]
      if item.kind == VkSymbol and item.str.endsWith(":"):
        let base = item.str[0..^2]
        array_data(out_args).add(base.to_symbol_value())
        i.inc
        if i < src.len:
          let type_val = src[i]
          if not type_id_map.hasKey(base):
            type_id_map[base] = resolve_type_value_to_id(type_val, type_descs, aliases, module_path)
          i.inc # Skip type expression
        continue
      elif item.kind == VkArray:
        array_data(out_args).add(strip_type_annotations(item, type_id_map, type_descs, aliases))
      else:
        array_data(out_args).add(item)
      i.inc
    return out_args

  # Apply collected TypeId annotations to matcher children
  proc apply_type_annotations(matcher: RootMatcher, type_id_map: Table[string, TypeId]) =
    if type_id_map.len == 0:
      return
    for child in matcher.children:
      try:
        let name = cast[Value](child.name_key).str
        if type_id_map.hasKey(name):
          child.type_id = type_id_map[name]
        if child.type_id != NO_TYPE_ID:
          matcher.has_type_annotations = true
      except CatchableError:
        discard
    # When type annotations are present, disable the simple-data fast path
    # so that process_args_core is always called (which does type validation)
    if matcher.has_type_annotations:
      matcher.hint_mode = MhDefault

  var name: string
  let matcher = new_arg_matcher()
  var body_start: int
  var is_generator = false
  var is_macro_like = false
  var type_id_map = initTable[string, TypeId]()

  if node.gene.children.len == 0:
    raise new_exception(type_defs.Exception, "Invalid function definition: expected name or argument list")
  let first = node.gene.children[0]
  case first.kind:
    of VkArray:
      name = "<unnamed>"
      matcher.parse(strip_type_annotations(first, type_id_map, type_descs, aliases))
      apply_type_annotations(matcher, type_id_map)
      body_start = 1
    of VkSymbol, VkString:
      name = first.str
      # Check if function name ends with ! (macro-like function)
      if name.len > 0 and name[^1] == '!':
        is_macro_like = true
      # Check if function name ends with * (generator function)
      elif name.len > 0 and name[^1] == '*':
        is_generator = true
      if node.gene.children.len < 2:
        raise new_exception(type_defs.Exception, "Invalid function definition: expected argument list array")
      let args = strip_type_annotations(node.gene.children[1], type_id_map, type_descs, aliases)
      if args.kind != VkArray:
        raise new_exception(type_defs.Exception, "Invalid function definition: arguments must be an array")
      matcher.parse(args)
      apply_type_annotations(matcher, type_id_map)
      body_start = 2
    of VkComplexSymbol:
      name = first.ref.csymbol[^1]
      # Check if function name ends with ! (macro-like function)
      if name.len > 0 and name[^1] == '!':
        is_macro_like = true
      # Check if function name ends with * (generator function)
      elif name.len > 0 and name[^1] == '*':
        is_generator = true
      if node.gene.children.len < 2:
        raise new_exception(type_defs.Exception, "Invalid function definition: expected argument list array")
      let args = strip_type_annotations(node.gene.children[1], type_id_map, type_descs, aliases)
      if args.kind != VkArray:
        raise new_exception(type_defs.Exception, "Invalid function definition: arguments must be an array")
      matcher.parse(args)
      apply_type_annotations(matcher, type_id_map)
      body_start = 2
    else:
      raise new_exception(type_defs.Exception, "Invalid function definition: expected name or argument list")

  matcher.check_hint()
  # Parse optional return type annotation: (-> Type)
  if body_start < node.gene.children.len:
    let maybe_arrow = node.gene.children[body_start]
    if maybe_arrow.kind == VkSymbol and maybe_arrow.str == "->":
      if body_start + 1 >= node.gene.children.len:
        raise new_exception(type_defs.Exception, "Invalid function definition: missing return type after ->")
      let ret_type = node.gene.children[body_start + 1]
      matcher.return_type_id = resolve_type_value_to_id(ret_type, type_descs, aliases, module_path)
      body_start += 2
  anchor_module_paths(type_descs, module_path)
  register_type_descs(type_registry, type_descs, module_path)
  # Attach the type_descs to the matcher for runtime validation
  matcher.type_descriptors = type_descs

  var body: seq[Value] = @[]
  for i in body_start..<node.gene.children.len:
    body.add node.gene.children[i]

  # Check if function has async attribute from properties
  var is_async = false
  let async_key = "async".to_key()
  if node.gene.props.has_key(async_key) and node.gene.props[async_key] == TRUE:
    is_async = true
    discard  # Function is async

  # Check if function has generator flag from properties (^^generator syntax)
  let generator_key = "generator".to_key()
  if node.gene.props.has_key(generator_key) and node.gene.props[generator_key] == TRUE:
    is_generator = true

  # body = wrap_with_try(body)
  result = new_fn(name, matcher, body)
  result.async = is_async
  result.is_generator = is_generator
  result.is_macro_like = is_macro_like

# compile method is defined in compiler.nim

#################### Block #######################

proc new_block*(matcher: RootMatcher,  body: sink seq[Value]): Block =
  return Block(
    matcher: matcher,
    # matching_hint: matcher.hint,
    body: body,
  )

proc to_block*(node: Value): Block {.gcsafe.} =
  let matcher = new_arg_matcher()
  var body_start: int
  let type_val = node.gene.type

  if type_val.kind == VkSymbol and type_val.str == "block":
    # New syntax: (block [args] body...)
    if node.gene.children.len > 0 and node.gene.children[0].kind == VkArray:
      matcher.parse(node.gene.children[0])
      body_start = 1
    else:
      # (block body...) with no args array - treat as empty args
      body_start = 0
  elif type_val == "->".to_symbol_value():
    # Old syntax: (-> body...) - no parameters
    body_start = 0
  else:
    # Old syntax: (params -> body...) - params is the type
    matcher.parse(type_val)
    body_start = 1

  matcher.check_hint()
  var body: seq[Value] = @[]
  for i in body_start..<node.gene.children.len:
    body.add node.gene.children[i]

  # body = wrap_with_try(body)
  result = new_block(matcher, body)

# compile method needs to be defined - see compiler.nim
