## Built-in type registry: BUILTIN_TYPE_* constants, builtin_type_descs,
## lookup_builtin_type, set_expected_type_id.
## Included from type_defs.nim — shares its scope.

#################### Built-in Type Registry ####################

const
  BUILTIN_TYPE_MODULE_PATH* = "stdlib"
  BUILTIN_TYPE_ANY_ID*: TypeId = 0
  BUILTIN_TYPE_INT_ID*: TypeId = 1
  BUILTIN_TYPE_FLOAT_ID*: TypeId = 2
  BUILTIN_TYPE_STRING_ID*: TypeId = 3
  BUILTIN_TYPE_BOOL_ID*: TypeId = 4
  BUILTIN_TYPE_NIL_ID*: TypeId = 5
  BUILTIN_TYPE_SYMBOL_ID*: TypeId = 6
  BUILTIN_TYPE_CHAR_ID*: TypeId = 7
  BUILTIN_TYPE_ARRAY_ID*: TypeId = 8
  BUILTIN_TYPE_MAP_ID*: TypeId = 9
  BUILTIN_TYPE_COUNT* = 10

proc builtin_type_descs*(): seq[TypeDesc] =
  ## Return the pre-created TypeDesc objects for all built-in types.
  ## Index positions match the BUILTIN_TYPE_*_ID constants.
  @[
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkAny),                             # 0 = Any
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Int"),             # 1 = Int
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Float"),           # 2 = Float
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "String"),          # 3 = String
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Bool"),            # 4 = Bool
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Nil"),             # 5 = Nil
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Symbol"),          # 6 = Symbol
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Char"),            # 7 = Char
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Array"),           # 8 = Array
    TypeDesc(module_path: BUILTIN_TYPE_MODULE_PATH, kind: TdkNamed, name: "Map"),             # 9 = Map
  ]

proc lookup_builtin_type*(name: string): TypeId =
  ## Look up a built-in type name and return its TypeId.
  ## Returns NO_TYPE_ID if name is not a built-in type.
  case name
  of "Any": BUILTIN_TYPE_ANY_ID
  of "Int", "int", "Int64", "int64", "i64": BUILTIN_TYPE_INT_ID
  of "Float", "float", "Float64", "float64", "f64": BUILTIN_TYPE_FLOAT_ID
  of "String", "string": BUILTIN_TYPE_STRING_ID
  of "Bool", "bool": BUILTIN_TYPE_BOOL_ID
  of "Nil", "nil": BUILTIN_TYPE_NIL_ID
  of "Symbol": BUILTIN_TYPE_SYMBOL_ID
  of "Char": BUILTIN_TYPE_CHAR_ID
  of "Array": BUILTIN_TYPE_ARRAY_ID
  of "Map": BUILTIN_TYPE_MAP_ID
  else: NO_TYPE_ID

proc module_path_from_source*(source_name: string): string {.inline.} =
  ## Map parser/compiler source names to a module path for descriptor ownership.
  ## Pseudo-inputs like <input> / <repl> are local and keep an empty module path.
  if source_name.len == 0:
    return ""
  if source_name[0] == '<':
    return ""
  source_name

const TYPE_DESC_MAX_DEPTH = 64

proc sorted_unique_strings(values: seq[string]): seq[string] {.gcsafe.} =
  if values.len == 0:
    return @[]
  result = values
  var i = 1
  while i < result.len:
    let item = result[i]
    var j = i
    while j > 0 and system.cmp(result[j - 1], item) > 0:
      result[j] = result[j - 1]
      j.dec()
    result[j] = item
    i.inc()

  var write = 0
  for item in result:
    if write == 0 or result[write - 1] != item:
      result[write] = item
      write.inc()
  result.setLen(write)

proc join_strings(values: seq[string], sep: string): string {.gcsafe.} =
  if values.len == 0:
    return ""
  result = values[0]
  for i in 1..<values.len:
    result &= sep
    result &= values[i]

proc type_desc_key_for_id(type_descs: seq[TypeDesc], type_id: TypeId, depth = 0): string {.gcsafe.}

proc type_desc_key(desc: TypeDesc, type_descs: seq[TypeDesc], depth = 0): string {.gcsafe.} =
  if depth > TYPE_DESC_MAX_DEPTH:
    return "any"

  let module_prefix = "module:" & desc.module_path & ";"
  case desc.kind
  of TdkAny:
    return module_prefix & "any"
  of TdkNamed:
    return module_prefix & "named:" & desc.name
  of TdkApplied:
    var parts: seq[string] = @[]
    for arg in desc.args:
      parts.add(type_desc_key_for_id(type_descs, arg, depth + 1))
    return module_prefix & "applied:" & desc.ctor & "[" & join_strings(parts, ",") & "]"
  of TdkUnion:
    var parts: seq[string] = @[]
    for member in desc.members:
      parts.add(type_desc_key_for_id(type_descs, member, depth + 1))
    return module_prefix & "union:" & join_strings(sorted_unique_strings(parts), "|")
  of TdkFn:
    var params: seq[string] = @[]
    for param in desc.params:
      params.add(type_desc_key_for_id(type_descs, param, depth + 1))
    let effects = sorted_unique_strings(desc.effects)
    return module_prefix & "fn:[" & join_strings(params, ",") & "]->" &
      type_desc_key_for_id(type_descs, desc.ret, depth + 1) &
      "!" & join_strings(effects, ",")
  of TdkVar:
    return module_prefix & "var:" & $desc.var_id

proc type_desc_key_for_id(type_descs: seq[TypeDesc], type_id: TypeId, depth = 0): string {.gcsafe.} =
  if type_id == NO_TYPE_ID:
    return "any"
  if type_id < 0 or type_id.int >= type_descs.len:
    return "any"
  type_desc_key(type_descs[type_id.int], type_descs, depth + 1)

proc normalize_type_id_list(type_descs: seq[TypeDesc], ids: seq[TypeId]): seq[TypeId] {.gcsafe.} =
  if ids.len == 0:
    return @[]

  var entries: seq[tuple[key: string, id: TypeId]] = @[]
  for id in ids:
    entries.add((key: type_desc_key_for_id(type_descs, id), id: id))

  var i = 1
  while i < entries.len:
    let item = entries[i]
    var j = i
    while j > 0 and system.cmp(entries[j - 1].key, item.key) > 0:
      entries[j] = entries[j - 1]
      j.dec()
    entries[j] = item
    i.inc()

  var last_key = ""
  for entry in entries:
    if result.len == 0 or entry.key != last_key:
      result.add(entry.id)
      last_key = entry.key

proc normalize_type_desc(desc: TypeDesc, type_descs: seq[TypeDesc]): TypeDesc {.gcsafe.} =
  result = desc
  if result.module_path.len == 0:
    case desc.kind
    of TdkAny:
      result.module_path = BUILTIN_TYPE_MODULE_PATH
    of TdkNamed:
      if lookup_builtin_type(desc.name) != NO_TYPE_ID:
        result.module_path = BUILTIN_TYPE_MODULE_PATH
    else:
      discard
  case desc.kind
  of TdkUnion:
    result.members = normalize_type_id_list(type_descs, desc.members)
  of TdkFn:
    result.effects = sorted_unique_strings(desc.effects)
  else:
    discard

proc ensure_type_desc_index*(type_descs: seq[TypeDesc], type_desc_index: var Table[string, TypeId]) {.gcsafe.} =
  ## Ensure an index table contains canonical descriptor keys for all type IDs.
  for i, desc in type_descs:
    let key = type_desc_key(desc, type_descs)
    if not type_desc_index.hasKey(key):
      type_desc_index[key] = i.TypeId

proc intern_type_desc*(type_descs: var seq[TypeDesc], desc: TypeDesc,
                       type_desc_index: var Table[string, TypeId]): TypeId {.gcsafe.} =
  ## Shared descriptor interner used by both compiler/matcher and type-checker paths.
  ensure_type_desc_index(type_descs, type_desc_index)
  let normalized = normalize_type_desc(desc, type_descs)
  let key = type_desc_key(normalized, type_descs)
  if type_desc_index.hasKey(key):
    return type_desc_index[key]
  let id = type_descs.len.TypeId
  type_descs.add(normalized)
  type_desc_index[key] = id
  id

proc intern_type_desc*(type_descs: var seq[TypeDesc], desc: TypeDesc): TypeId {.gcsafe.} =
  ## Compatibility wrapper for existing call sites that don't carry an index table.
  var type_desc_index = initTable[string, TypeId]()
  intern_type_desc(type_descs, desc, type_desc_index)

proc set_expected_type_id*(tracker: ScopeTracker, index: int16,
                          expected_type_id: TypeId) {.inline.} =
  ## Store a TypeId expectation for a variable slot in the scope tracker.
  if tracker == nil or expected_type_id == NO_TYPE_ID:
    return
  while tracker.type_expectation_ids.len <= index.int:
    tracker.type_expectation_ids.add(NO_TYPE_ID)
  tracker.type_expectation_ids[index.int] = expected_type_id

proc new_global_type_registry*(): GlobalTypeRegistry =
  GlobalTypeRegistry(modules: initOrderedTable[string, ModuleTypeRegistry]())

proc get_or_create_module*(g: GlobalTypeRegistry, path: string): ModuleTypeRegistry =
  if path in g.modules:
    return g.modules[path]
  result = ModuleTypeRegistry(
    module_path: path,
    descriptors: initOrderedTable[TypeId, TypeDesc](),
  )
  g.modules[path] = result

proc populate_registry*(cu_type_descriptors: seq[TypeDesc]): ModuleTypeRegistry =
  ## Build a ModuleTypeRegistry from a flat seq[TypeDesc] (legacy format).
  ## Groups descriptors by module_path; returns a single registry for the
  ## primary module (uses the first non-"stdlib" module_path found, or "").
  var module_path = ""
  for desc in cu_type_descriptors:
    if desc.module_path != "stdlib" and desc.module_path != "":
      module_path = desc.module_path
      break
  result = ModuleTypeRegistry(
    module_path: module_path,
    descriptors: initOrderedTable[TypeId, TypeDesc](),
  )
  for i, desc in cu_type_descriptors:
    result.descriptors[i.TypeId] = desc
