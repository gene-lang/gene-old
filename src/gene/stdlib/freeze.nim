import std/[sets, tables]

import ../types

type
  ## Raised when `(freeze)` is asked to produce a frozen value outside the
  ## Phase 1 MVP container scope.
  FreezeScopeError* = object of CatchableError
    offending_kind*: ValueKind
    path*: string

proc symbol_name(key: Key): string =
  let symbol_value = cast[Value](key)
  let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
  get_symbol(symbol_index.int)

proc append_path(path, segment: string): string =
  if path == "/":
    "/" & segment
  else:
    path & "/" & segment

proc reject_freeze(v: Value, path: string) {.noreturn.} =
  let err = newException(
    FreezeScopeError,
    "freeze cannot make " & $v.kind & " frozen at " & path &
      "; Phase 1 only deep-freezes MVP containers, and sealed non-MVP values stay shallow"
  )
  err.offending_kind = v.kind
  err.path = path
  raise err

proc already_seen(v: Value, visited: var HashSet[uint64]): bool =
  if not isManaged(v):
    return false

  let id = cast[uint64](v) and PAYLOAD_MASK
  if id == 0:
    return false
  if id in visited:
    return true

  visited.incl(id)
  false

proc already_seen_scope(scope: Scope, visited: var HashSet[uint64]): bool =
  if scope == nil:
    return true

  let id = cast[uint64](scope)
  if id == 0:
    return true
  if id in visited:
    return true

  visited.incl(id)
  false

proc capture_segment(scope: Scope, slot: int): string =
  if scope != nil and scope.tracker != nil:
    for key, index in scope.tracker.mappings:
      if index == slot.int16:
        return "<capture:" & symbol_name(key) & ">"

  "<slot:" & $slot & ">"

proc validate_for_freeze*(v: Value, path: string, visited: var HashSet[uint64])
proc tag_for_freeze*(v: Value, visited: var HashSet[uint64])

proc validate_scope_for_freeze(scope: Scope, path: string, depth: int, visited: var HashSet[uint64]) =
  if already_seen_scope(scope, visited):
    return

  let scope_path = append_path(append_path(path, "<closure>"), "<scope:" & $depth & ">")
  for i, item in scope.members:
    validate_for_freeze(item, append_path(scope_path, capture_segment(scope, i)), visited)

  validate_scope_for_freeze(scope.parent, path, depth + 1, visited)

proc tag_scope_for_freeze(scope: Scope, visited: var HashSet[uint64]) =
  if already_seen_scope(scope, visited):
    return

  for item in scope.members:
    tag_for_freeze(item, visited)

  tag_scope_for_freeze(scope.parent, visited)

proc validate_for_freeze*(v: Value, path: string, visited: var HashSet[uint64]) =
  if v.deep_frozen or already_seen(v, visited):
    return

  case v.kind
  of VkNil, VkBool, VkInt, VkFloat, VkChar, VkSymbol, VkComplexSymbol, VkString, VkBytes:
    return
  of VkArray:
    for i, item in array_data(v):
      validate_for_freeze(item, append_path(path, "[" & $i & "]"), visited)
  of VkMap:
    for key, value in map_data(v):
      validate_for_freeze(value, append_path(path, "." & symbol_name(key)), visited)
  of VkHashMap:
    var pair_index = 0
    var i = 0
    while i < hash_map_items(v).len:
      validate_for_freeze(hash_map_items(v)[i], append_path(path, "key[" & $pair_index & "]"), visited)
      if i + 1 < hash_map_items(v).len:
        validate_for_freeze(hash_map_items(v)[i + 1], append_path(path, "value[" & $pair_index & "]"), visited)
      inc(pair_index)
      i += 2
  of VkGene:
    if not v.gene.type.is_nil:
      validate_for_freeze(v.gene.type, append_path(path, "type"), visited)
    for key, value in v.gene.props:
      validate_for_freeze(value, append_path(path, "." & symbol_name(key)), visited)
    for i, child in v.gene.children:
      validate_for_freeze(child, append_path(path, "children[" & $i & "]"), visited)
  of VkFunction:
    if v.ref.fn != nil:
      validate_scope_for_freeze(v.ref.fn.parent_scope, path, 0, visited)
  else:
    reject_freeze(v, path)

proc tag_for_freeze*(v: Value, visited: var HashSet[uint64]) =
  if v.deep_frozen or already_seen(v, visited):
    return

  case v.kind
  of VkString, VkBytes:
    if isManaged(v):
      setDeepFrozen(v)
      setShared(v)
  of VkArray:
    setDeepFrozen(v)
    setShared(v)
    for item in array_data(v):
      tag_for_freeze(item, visited)
  of VkMap:
    setDeepFrozen(v)
    setShared(v)
    for _, value in map_data(v):
      tag_for_freeze(value, visited)
  of VkHashMap:
    setDeepFrozen(v)
    setShared(v)
    for item in hash_map_items(v):
      tag_for_freeze(item, visited)
  of VkGene:
    setDeepFrozen(v)
    setShared(v)
    if not v.gene.type.is_nil:
      tag_for_freeze(v.gene.type, visited)
    for _, value in v.gene.props:
      tag_for_freeze(value, visited)
    for child in v.gene.children:
      tag_for_freeze(child, visited)
  of VkFunction:
    setDeepFrozen(v)
    setShared(v)
    if v.ref.fn != nil:
      tag_scope_for_freeze(v.ref.fn.parent_scope, visited)
  else:
    discard

## Recursively deep-freezes a value over the Phase 1 MVP container scope.
## Sealed literals stay shallow until user code explicitly calls `(freeze v)`.
proc freeze_value*(v: Value): Value =
  if v.deep_frozen:
    return v

  var visited1 = initHashSet[uint64]()
  validate_for_freeze(v, "/", visited1)

  var visited2 = initHashSet[uint64]()
  tag_for_freeze(v, visited2)
  v

proc core_freeze_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional != 1:
    raise new_exception(types.Exception, "freeze requires 1 argument")

  freeze_value(get_positional_arg(args, 0, has_keyword_args))

## Stdlib entry point for `(freeze v)`: produce a fully frozen graph while
## keeping shallow sealed literals as a separate concept.
proc core_freeze*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    core_freeze_impl(vm, args, arg_count, has_keyword_args)
