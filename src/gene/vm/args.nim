import tables, sets
import ../types
import ../types/runtime_types

proc resolve_property_instance(scope: Scope): Value =
  if scope.is_nil or scope.tracker.is_nil:
    return NIL
  let selfKey = "self".to_key()
  if scope.tracker.mappings.hasKey(selfKey):
    let idx = scope.tracker.mappings[selfKey]
    if idx.int < scope.members.len:
      return scope.members[idx.int]
  NIL

proc assign_property_params*(matcher: RootMatcher, scope: Scope, explicit_instance: Value = NIL) =
  ## Assign shorthand property parameters (e.g. [/x]) directly onto the instance.
  if matcher.is_nil or scope.is_nil or matcher.children.len == 0:
    return

  var instance = explicit_instance
  if instance == NIL:
    instance = resolve_property_instance(scope)

  if instance.kind != VkInstance:
    return

  for i, param in matcher.children:
    if param.is_prop and i < scope.members.len:
      let value = scope.members[i]
      if value.kind != VkNil:
        instance_props(instance)[param.name_key] = value

# Forward declaration for original process_args function
proc process_args*(matcher: RootMatcher, args: Value, scope: Scope)

template is_simple_positional(matcher: RootMatcher, arg_count: int): bool =
  matcher.hint_mode == MhSimpleData and matcher.children.len == arg_count

template ensure_scope_capacity(scope: Scope, count: int) =
  while scope.members.len < count:
    scope.members.add(NIL)

proc key_to_name(key: Key): string {.inline.} =
  try:
    result = cast[Value](key).str
  except CatchableError:
    result = "<keyword>"

proc process_args_core(matcher: RootMatcher, positional: ptr UncheckedArray[Value],
                      pos_count: int, keywords: seq[(Key, Value)],
                      scope: Scope) {.inline.} =
  ## Shared argument binding logic for positional/keyword combinations.
  while scope.members.len < matcher.children.len:
    scope.members.add(NIL)
  for i in 0..<matcher.children.len:
    scope.members[i] = NIL

  var used_param_indices = initHashSet[int]()
  var used_keys = initHashSet[Key]()
  var prop_splat_index = -1

  if keywords.len > 0:
    var kw_table = initTable[Key, Value]()
    for (k, v) in keywords:
      kw_table[k] = v

    for i, param in matcher.children:
      if (param.kind == MatchProp or param.is_prop) and kw_table.hasKey(param.name_key):
        scope.members[i] = kw_table[param.name_key]
        used_param_indices.incl(i)
        used_keys.incl(param.name_key)

  var pos_index = 0
  var has_value_splat = false
  for i, param in matcher.children:
    if i in used_param_indices:
      continue

    let is_prop_param = param.kind == MatchProp or param.is_prop
    if is_prop_param:
      if param.is_splat:
        if prop_splat_index < 0:
          prop_splat_index = i
      elif param.has_default():
        scope.members[i] = param.default_value
      elif param.required():
        let name = key_to_name(param.name_key)
        raise new_exception(types.Exception, "Missing keyword argument: " & name)
      continue

    if param.is_splat:
      let rest_array = new_array_value()
      while pos_index < pos_count:
        array_data(rest_array).add(positional[pos_index])
        pos_index.inc()
      scope.members[i] = rest_array
      has_value_splat = true
    elif param.has_default():
      if pos_index < pos_count:
        let remaining = pos_count - pos_index
        if remaining > param.min_left:
          scope.members[i] = positional[pos_index]
          pos_index.inc()
        else:
          scope.members[i] = param.default_value
      else:
        scope.members[i] = param.default_value
    elif pos_index < pos_count:
      scope.members[i] = positional[pos_index]
      pos_index.inc()
    elif param.required():
      raise new_exception(types.Exception, "Expected " & $(i + 1) & " arguments, got " & $pos_count)

  if prop_splat_index >= 0:
    var rest_map = new_map_value()
    if keywords.len > 0:
      for (k, v) in keywords:
        if k notin used_keys:
          map_data(rest_map)[k] = v
    scope.members[prop_splat_index] = rest_map

  if not has_value_splat and pos_index < pos_count:
    raise new_exception(types.Exception, "Expected " & $pos_index & " arguments, got " & $pos_count)

  # Runtime type validation for annotated parameters
  if matcher.type_check and matcher.has_type_annotations:
    for i, param in matcher.children:
      if param.type_id != NO_TYPE_ID and matcher.type_descriptors.len > 0 and i < scope.members.len:
        var value = scope.members[i]
        if value != NIL:  # Don't validate nil/missing args (handled by required check)
          let warning = validate_or_coerce_type(value, param.type_id, matcher.type_descriptors, key_to_name(param.name_key))
          scope.members[i] = value
          emit_type_warning(warning)

  assign_property_params(matcher, scope)

# Inline type validation for fast paths
template validate_fast_path_types(matcher: RootMatcher, scope: Scope) =
  if matcher.type_check and matcher.has_type_annotations:
    for i, param in matcher.children:
      if param.type_id != NO_TYPE_ID and matcher.type_descriptors.len > 0 and i < scope.members.len:
        var value = scope.members[i]
        if value != NIL:
          let warning = validate_or_coerce_type(value, param.type_id, matcher.type_descriptors, key_to_name(param.name_key))
          scope.members[i] = value
          emit_type_warning(warning)

# Optimized version for zero arguments
proc process_args_zero*(matcher: RootMatcher, scope: Scope) {.inline.} =
  ## Ultra-fast path for zero-argument functions
  if matcher.is_simple_positional(0):
    return
  process_args_core(matcher, cast[ptr UncheckedArray[Value]](nil), 0, @[], scope)

# Optimized version for single argument
proc process_args_one*(matcher: RootMatcher, arg: Value, scope: Scope) {.inline.} =
  ## Ultra-fast path for single-argument functions
  if matcher.is_simple_positional(1) and not matcher.has_type_annotations:
    ensure_scope_capacity(scope, 1)
    scope.members[0] = arg
    return
  var arr = [arg]
  process_args_core(matcher, cast[ptr UncheckedArray[Value]](arr[0].addr), 1, @[], scope)

proc process_args_direct*(matcher: RootMatcher, args: ptr UncheckedArray[Value],
                         arg_count: int, has_keyword_args: bool, scope: Scope) {.inline.} =
  ## Process arguments directly from stack to scope
  ## Supports positional arguments only (keywords handled by process_args_direct_kw).
  if (not has_keyword_args) and matcher.is_simple_positional(arg_count) and not matcher.has_type_annotations:
    ensure_scope_capacity(scope, arg_count)
    {.push checks: off.}
    var i = 0
    while i < arg_count:
      scope.members[i] = args[i]
      inc i
    {.pop.}
    return

  process_args_core(matcher, args, arg_count, @[], scope)

proc process_args_direct_kw*(matcher: RootMatcher, positional: ptr UncheckedArray[Value],
                            pos_count: int, keywords: seq[(Key, Value)],
                            scope: Scope) {.inline.} =
  ## Optimized processing when keyword arguments are provided separately.
  process_args_core(matcher, positional, pos_count, keywords, scope)

proc process_args*(matcher: RootMatcher, args: Value, scope: Scope) =
  ## Process function arguments and bind them to the scope
  ## Handles both positional and named arguments

  if args.kind == VkGene:
    if args.gene.props.len == 0 and matcher.is_simple_positional(args.gene.children.len) and not matcher.has_type_annotations:
      ensure_scope_capacity(scope, args.gene.children.len)
      {.push checks: off.}
      var i = 0
      while i < args.gene.children.len:
        scope.members[i] = args.gene.children[i]
        inc i
      {.pop.}
      return

    var positional: seq[Value] = @[]
    var keywords: seq[(Key, Value)] = @[]

    positional = args.gene.children
    for k, v in args.gene.props:
      keywords.add((k, v))

    let pos_ptr = if positional.len > 0: cast[ptr UncheckedArray[Value]](positional[0].addr)
                  else: cast[ptr UncheckedArray[Value]](nil)
    process_args_core(matcher, pos_ptr, positional.len, keywords, scope)
  else:
    process_args_core(matcher, cast[ptr UncheckedArray[Value]](nil), 0, @[], scope)

proc split_destructure_input(input: Value): tuple[positional: seq[Value], keywords: seq[(Key, Value)]] =
  ## Adapt a runtime value to matcher-style positional/keyword inputs.
  ## This lets `(var [pattern] value)` share the same binding semantics as function args.
  result.positional = @[]
  result.keywords = @[]
  case input.kind
  of VkGene:
    result.positional = input.gene.children
    for k, v in input.gene.props:
      result.keywords.add((k, v))
  of VkArray:
    result.positional = array_data(input)
  of VkMap:
    for k, v in map_data(input):
      result.keywords.add((k, v))
  else:
    result.positional = @[input]

proc bind_destructure_pattern*(pattern: Value, input: Value, scope: Scope, target_indices: seq[int16]) =
  ## Bind a var-destructuring pattern using the same matcher pipeline as function args.
  if scope.is_nil:
    not_allowed("Destructuring target scope is nil")

  let matcher = new_arg_matcher(pattern)
  let (positional, keywords) = split_destructure_input(input)
  let pos_ptr = if positional.len > 0: cast[ptr UncheckedArray[Value]](positional[0].addr)
                else: cast[ptr UncheckedArray[Value]](nil)

  let temp_scope = new_scope(new_scope_tracker())
  try:
    process_args_core(matcher, pos_ptr, positional.len, keywords, temp_scope)
    let count = min(target_indices.len, temp_scope.members.len)
    for i in 0..<count:
      let target = target_indices[i]
      if target >= 0:
        let idx = target.int
        while scope.members.len <= idx:
          scope.members.add(NIL)
        scope.members[idx] = temp_scope.members[i]
  finally:
    temp_scope.free()
