## Application, Namespace operations, Scope operations, ScopeTracker.
## Included from core.nim — shares its scope.

#################### Application #################

# Forward decls for namespace helpers used here
proc new_namespace*(): Namespace {.gcsafe.}
proc new_namespace*(name: string): Namespace {.gcsafe.}
proc new_namespace*(parent: Namespace): Namespace {.gcsafe.}

proc app*(self: Value): Application {.inline.} =
  self.ref.app

proc new_app*(): Application =
  result = Application()
  let global = new_namespace("global")
  result.ns = global

#################### Namespace ###################

proc ns*(self: Value): Namespace {.inline.} =
  self.ref.ns

proc to_value*(self: Namespace): Value {.inline.} =
  let r = new_ref(VkNamespace)
  r.ns = self
  result = r.to_ref_value()

proc new_namespace*(): Namespace =
  return Namespace(
    name: "<root>",
    members: Table[Key, Value](),
  )

proc new_namespace*(parent: Namespace): Namespace =
  return Namespace(
    parent: parent,
    name: "<root>",
    members: Table[Key, Value](),
  )

proc new_namespace*(name: string): Namespace =
  return Namespace(
    name: name,
    members: Table[Key, Value](),
  )

proc new_namespace*(parent: Namespace, name: string): Namespace =
  return Namespace(
    parent: parent,
    name: name,
    members: Table[Key, Value](),
  )

proc root*(self: Namespace): Namespace =
  if self.name == "<root>":
    return self
  else:
    return self.parent.root

proc get_module*(self: Namespace): Module =
  if self.module == nil:
    if self.parent != nil:
      return self.parent.get_module()
    else:
      return
  else:
    return self.module

proc package*(self: Namespace): Package =
  self.get_module().pkg

proc has_key*(self: Namespace, key: Key): bool {.inline.} =
  return self.members.has_key(key) or (self.parent != nil and self.parent.has_key(key))

proc `[]`*(self: Namespace, key: Key): Value =
  let found = self.members.get_or_default(key, NOT_FOUND)
  if found != NOT_FOUND:
    return found
  elif not self.stop_inheritance and self.parent != nil:
    return self.parent[key]
  else:
    return NIL
    # return NOT_FOUND
    # raise new_exception(NotDefinedException, get_symbol(key.int64) & " is not defined")

proc locate*(self: Namespace, key: Key): (Value, Namespace) =
  let found = self.members.get_or_default(key, NOT_FOUND)
  if found != NOT_FOUND:
    result = (found, self)
  elif not self.stop_inheritance and self.parent != nil:
    result = self.parent.locate(key)
  else:
    not_allowed()

proc `[]=`*(self: Namespace, key: Key, val: Value) {.inline.} =
  self.members[key] = val
  self.version.inc()  # Invalidate caches on mutation

proc get_members*(self: Namespace): Value =
  todo()
  # result = new_gene_map()
  # for k, v in self.members:
  #   result.map[k] = v

proc member_names*(self: Namespace): Value =
  todo()
  # result = new_gene_vec()
  # for k, _ in self.members:
  #   result.vec.add(k)

# on_member_missing is now implemented as a native method on namespace_class
# in stdlib/core.nim via try_member_missing_handlers in vm/module.nim

#################### Scope #######################

# Scope pooling for performance (like Frame pooling)
var SCOPES* {.threadvar.}: seq[Scope]
var SCOPE_ALLOCS* {.threadvar.}: int
var SCOPE_REUSES* {.threadvar.}: int

proc reset_scope*(self: Scope) {.inline.} =
  ## Reset a scope for reuse from pool
  self.tracker = nil
  self.parent = nil
  self.members.setLen(0)  # Clear members but keep capacity

proc free*(self: Scope) =
  {.push checks: off, optimization: speed.}
  self.ref_count.dec()
  if self.ref_count == 0:
    # Free parent first
    if self.parent != nil:
      self.parent.free()
    # Return to pool instead of deallocating
    self.reset_scope()
    SCOPES.add(self)
  {.pop.}

proc new_scope*(tracker: ScopeTracker): Scope {.inline.} =
  {.push checks: off, optimization: speed.}
  if SCOPES.len > 0:
    result = SCOPES.pop()
    SCOPE_REUSES.inc()
  else:
    result = cast[Scope](alloc0(sizeof(ScopeObj)))
    result.members = newSeq[Value]()  # Only allocate members seq on first creation
    SCOPE_ALLOCS.inc()
  result.ref_count = 1
  result.tracker = tracker
  result.parent = nil
  {.pop.}

proc update*(self: var Scope, scope: Scope) {.inline.} =
  {.push checks: off, optimization: speed.}
  if scope != nil:
    scope.ref_count.inc()
  if self != nil:
    self.free()
  self = scope
  {.pop.}

proc max*(self: Scope): int16 {.inline.} =
  return self.members.len.int16

proc set_parent*(self: Scope, parent: Scope) {.inline.} =
  parent.ref_count.inc()
  self.parent = parent

proc new_scope*(tracker: ScopeTracker, parent: Scope): Scope =
  result = new_scope(tracker)
  if not parent.is_nil():
    result.set_parent(parent)

proc locate(self: ScopeTracker, key: Key, max: int): VarIndex =
  let found = self.mappings.get_or_default(key, -1)
  if found >= 0 and found < max:
    return VarIndex(parent_index: 0, local_index: found)
  elif self.parent.is_nil():
    return VarIndex(parent_index: 0, local_index: -1)
  else:
    result = self.parent.locate(key, self.parent_index_max.int)
    if self.next_index > 0: # if current scope is not empty
      result.parent_index.inc()

proc locate*(self: ScopeTracker, key: Key): VarIndex =
  let found = self.mappings.get_or_default(key, -1)
  if found >= 0:
    return VarIndex(parent_index: 0, local_index: found)
  elif self.parent.is_nil():
    return VarIndex(parent_index: 0, local_index: -1)
  else:
    result = self.parent.locate(key, self.parent_index_max.int)
    # Only increment parent_index if we actually created a runtime scope
    # (indicated by scope_started flag or having variables)
    if self.next_index > 0 or self.scope_started:
      result.parent_index.inc()

#################### ScopeTracker ################

proc new_scope_tracker*(): ScopeTracker =
  ScopeTracker()

proc new_scope_tracker*(parent: ScopeTracker): ScopeTracker =
  result = ScopeTracker()
  var p = parent
  while p != nil:
    if p.next_index > 0:
      result.parent = p
      result.parent_index_max = p.next_index
      return
    p = p.parent

proc copy_scope_tracker*(source: ScopeTracker): ScopeTracker =
  result = ScopeTracker()
  result.next_index = source.next_index
  result.parent_index_max = source.parent_index_max
  result.parent = source.parent
  result.type_expectation_ids = source.type_expectation_ids
  # Copy the mappings table
  for key, value in source.mappings:
    result.mappings[key] = value

proc add*(self: var ScopeTracker, name: Key) =
  self.mappings[name] = self.next_index
  self.next_index.inc()

proc snapshot_scope_tracker*(tracker: ScopeTracker): ScopeTrackerSnapshot =
  if tracker == nil:
    return nil

  result = ScopeTrackerSnapshot(
    next_index: tracker.next_index,
    parent_index_max: tracker.parent_index_max,
    scope_started: tracker.scope_started,
    mappings: @[],
    type_expectation_ids: tracker.type_expectation_ids,
    parent: snapshot_scope_tracker(tracker.parent)
  )

  for key, value in tracker.mappings:
    result.mappings.add((key, value))

proc materialize_scope_tracker*(snapshot: ScopeTrackerSnapshot): ScopeTracker =
  if snapshot == nil:
    return nil

  result = ScopeTracker(
    next_index: snapshot.next_index,
    parent_index_max: snapshot.parent_index_max,
    scope_started: snapshot.scope_started,
    type_expectation_ids: snapshot.type_expectation_ids,
    parent: materialize_scope_tracker(snapshot.parent)
  )

  for pair in snapshot.mappings:
    result.mappings[pair[0]] = pair[1]

proc new_function_def_info*(tracker: ScopeTracker, body: CompilationUnit = nil, input: Value = NIL,
                            type_expectation_ids: seq[TypeId] = @[],
                            return_type_id: TypeId = NO_TYPE_ID): FunctionDefInfo =
  var body_value = NIL
  if body != nil:
    let cu_ref = new_ref(VkCompiledUnit)
    cu_ref.cu = body
    body_value = cu_ref.to_ref_value()

  result = FunctionDefInfo(
    input: input,
    scope_tracker: tracker,
    compiled_body: body_value,
    type_expectation_ids: type_expectation_ids,
    return_type_id: return_type_id
  )

proc to_value*(info: FunctionDefInfo): Value =
  let r = new_ref(VkFunctionDef)
  r.function_def = info
  result = r.to_ref_value()

proc to_function_def_info*(value: Value): FunctionDefInfo =
  if value.kind != VkFunctionDef:
    not_allowed("Expected FunctionDef info value")
  result = value.ref.function_def
