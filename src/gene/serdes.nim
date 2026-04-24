import tables, strutils, sets, os, algorithm, hashes
import std/json
import std/uri

import ./types
import ./parser

type
  Serialization* = ref object
    references*: Table[string, Value]
    data*: Value

  SerializationRefKind* = enum
    SrkNamespace
    SrkClass
    SrkFunction
    SrkEnum
    SrkInstance

  SerializationOrigin* = object
    module_path*: string
    internal_path*: string
    kind*: SerializationRefKind

  SerdesModuleLoaderHook* = proc(module_path: string): Namespace {.nimcall.}

  TreeWriteOptions = object
    directory_nodes: HashSet[string]

  LazyTreeReadOptions = object
    enabled: bool
    lazy_nodes: HashSet[string]

  FilesystemTreeReadStats* = object
    serialized_file_reads*: int
    dir_listings*: int

  LazyTreeSourceKind = enum
    LtsFile
    LtsDirectory

  LazyTreeValueData = ref object of CustomValue
    path: string
    source_kind: LazyTreeSourceKind
    node_segments: seq[string]
    options: LazyTreeReadOptions
    materialized: Value
    materialized_loaded: bool

var
  tree_read_stats {.threadvar.}: FilesystemTreeReadStats
  lazy_tree_value_class {.threadvar.}: Class
  # Cache serialization origins per thread by raw Value identity.
  #
  # Using value.raw is appropriate for Gene's NaN-boxed Value model: the same
  # runtime object is normally observed through the same raw payload, and the
  # canonical origin is also stamped onto the underlying object when available.
  value_origin_registry {.threadvar.}: Table[uint64, SerializationOrigin]
  value_origin_registry_ready {.threadvar.}: bool
  serdes_module_loader_hook*: SerdesModuleLoaderHook

proc serialize*(self: Serialization, value: Value): Value {.gcsafe.}
proc to_path*(self: Value): string {.gcsafe.}
proc to_path*(self: Class): string {.gcsafe.}
proc is_literal_value*(v: Value): bool {.inline, gcsafe.}
proc serialize_literal*(value: Value): Serialization {.gcsafe.}
proc deserialize*(s: string): Value {.gcsafe.}
proc deserialize_literal*(s: string): Value {.gcsafe.}
proc to_s*(self: Serialization): string
proc path_to_value*(path: string): Value {.gcsafe.}
proc tag_namespace_serialization_origins*(ns: Namespace, module_path: string, prefix = "") {.gcsafe.}
proc tag_stdlib_serialization_origins*() {.gcsafe.}
proc set_serdes_module_loader_hook*(hook: SerdesModuleLoaderHook) {.inline.}

proc key_to_string(k: Key): string {.inline, gcsafe.}

proc read_tree_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.}

const
  TreeGeneTypeName = "_genetype"
  TreeGenePropsName = "_geneprops"
  TreeGeneChildrenName = "_genechildren"
  TreeArrayName = "_genearray"

proc reset_tree_read_stats*() =
  tree_read_stats = FilesystemTreeReadStats()

proc filesystem_tree_read_stats*(): FilesystemTreeReadStats =
  tree_read_stats

proc count_tree_serialized_file_read() {.inline, gcsafe.} =
  tree_read_stats.serialized_file_reads.inc()

proc count_tree_dir_listing() {.inline, gcsafe.} =
  tree_read_stats.dir_listings.inc()

proc is_lazy_tree_value*(value: Value): bool {.inline, gcsafe.} =
  if value.kind != VkCustom:
    return false
  let ref_data = value.ref
  if cast[pointer](ref_data) == nil:
    return false
  let custom_data = ref_data.custom_data
  if cast[pointer](custom_data) == nil:
    return false
  custom_data of LazyTreeValueData

proc materialize_lazy_tree_value*(value: Value): Value {.gcsafe.}
proc materialize_lazy_tree_deep*(value: Value): Value {.gcsafe.}
proc find_live_origin(target: Value): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.}
proc class_to_value(self: Class): Value {.inline, gcsafe.}
proc namespace_runtime_module_path(ns: Namespace): string {.gcsafe.}
proc simple_member_origin(ns: Namespace, name: string, target: Value,
                          kind: SerializationRefKind): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.}

proc set_serdes_module_loader_hook*(hook: SerdesModuleLoaderHook) {.inline.} =
  serdes_module_loader_hook = hook

proc ensure_value_origin_registry() {.inline, gcsafe.} =
  if not value_origin_registry_ready:
    value_origin_registry = initTable[uint64, SerializationOrigin]()
    value_origin_registry_ready = true

proc ref_kind_name(kind: SerializationRefKind): string {.inline.} =
  case kind:
  of SrkNamespace: "NamespaceRef"
  of SrkClass: "ClassRef"
  of SrkFunction: "FunctionRef"
  of SrkEnum: "EnumRef"
  of SrkInstance: "InstanceRef"

proc make_origin(kind: SerializationRefKind, module_path, internal_path: string): SerializationOrigin {.inline.} =
  SerializationOrigin(
    module_path: module_path,
    internal_path: internal_path,
    kind: kind,
  )

proc join_origin_path(prefix, name: string): string {.inline.} =
  if prefix.len == 0:
    return name
  prefix & "/" & name

proc new_typed_ref(kind: SerializationRefKind, internal_path: string, module_path = ""): Value =
  let gene = new_gene(ref_kind_name(kind).to_symbol_value())
  gene.props["path".to_key()] = internal_path.to_value()
  if module_path.len > 0:
    gene.props["module".to_key()] = module_path.to_value()
  gene.to_gene_value()

proc new_serialized_instance(class_ref: Value, props: Value): Value =
  let gene = new_gene("Instance".to_symbol_value())
  gene.children.add(class_ref)
  gene.children.add(props)
  gene.to_gene_value()

proc new_legacy_gene_ref(path: string): Value =
  let gene = new_gene("gene/ref".to_symbol_value())
  gene.children.add(path.to_value())
  gene.to_gene_value()

proc new_legacy_gene_instance(class_ref: Value, props: Value): Value =
  let gene = new_gene("gene/instance".to_symbol_value())
  gene.children.add(class_ref)
  gene.children.add(props)
  gene.to_gene_value()

proc should_skip_origin_member(name: string): bool {.inline.} =
  name.len == 0 or name.startsWith("__") or name == "gene" or name == "genex"

proc namespace_has_explicit_exports(ns: Namespace): bool {.inline, gcsafe.} =
  if ns == nil:
    return false
  let exports_val = ns.members.getOrDefault("__exports__".to_key(), NIL)
  exports_val != NIL and exports_val.kind == VkMap

proc namespace_path_is_exported(ns: Namespace, path: string): bool {.gcsafe.} =
  if ns == nil:
    return false
  let exports_val = ns.members.getOrDefault("__exports__".to_key(), NIL)
  if exports_val == NIL or exports_val.kind != VkMap:
    return true
  let exports_map = map_data(exports_val)
  if exports_map.hasKey(path.to_key()):
    return true
  let parts = path.split("/")
  if parts.len > 1:
    var prefix = ""
    for i in 0..<parts.len - 1:
      prefix = join_origin_path(prefix, parts[i])
      if exports_map.hasKey(prefix.to_key()):
        return true
  false

proc register_value_origin(value: Value, origin: SerializationOrigin) {.gcsafe.} =
  ensure_value_origin_registry()
  value_origin_registry[value.raw] = origin

proc assign_value_origin(value: Value, origin: SerializationOrigin) {.gcsafe.} =
  register_value_origin(value, origin)
  case value.kind:
  of VkNamespace:
    if value.ref.ns != nil:
      value.ref.ns.module_path = origin.module_path
      value.ref.ns.internal_path = origin.internal_path
  of VkClass:
    if value.ref.class != nil:
      value.ref.class.module_path = origin.module_path
      value.ref.class.internal_path = origin.internal_path
  of VkFunction:
    if value.ref.fn != nil:
      value.ref.fn.module_path = origin.module_path
      value.ref.fn.internal_path = origin.internal_path
  of VkEnum:
    if value.ref.enum_def != nil:
      value.ref.enum_def.module_path = origin.module_path
      value.ref.enum_def.internal_path = origin.internal_path
      for member_name, member in value.ref.enum_def.members:
        if member != nil:
          let member_origin = make_origin(SrkEnum, origin.module_path,
            join_origin_path(origin.internal_path, member_name))
          member.module_path = member_origin.module_path
          member.internal_path = member_origin.internal_path
          register_value_origin(member.to_value(), member_origin)
  of VkEnumMember:
    if value.ref.enum_member != nil:
      value.ref.enum_member.module_path = origin.module_path
      value.ref.enum_member.internal_path = origin.internal_path
  of VkInstance:
    let data = instance_ptr(value)
    if data != nil:
      data.module_path = origin.module_path
      data.internal_path = origin.internal_path
  else:
    discard

proc lookup_class_origin(self: Class): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.} =
  if self != nil and self.internal_path.len > 0:
    return (true, make_origin(SrkClass, self.module_path, self.internal_path))
  if self != nil and self.name.len > 0:
    let target = class_to_value(self)
    if VM != nil and VM.frame != nil and VM.frame.ns != nil:
      let current = simple_member_origin(VM.frame.ns, self.name, target, SrkClass)
      if current.found:
        self.module_path = current.origin.module_path
        self.internal_path = current.origin.internal_path
        return current
    if App != NIL and App.kind == VkApplication and App.app.global_ns.kind == VkNamespace:
      let global = simple_member_origin(App.app.global_ns.ref.ns, self.name, target, SrkClass)
      if global.found:
        self.module_path = global.origin.module_path
        self.internal_path = global.origin.internal_path
        return global
  if self != nil:
    let live = find_live_origin(class_to_value(self))
    if live.found:
      self.module_path = live.origin.module_path
      self.internal_path = live.origin.internal_path
      return (true, make_origin(SrkClass, self.module_path, self.internal_path))
  (false, SerializationOrigin())

proc namespace_runtime_module_path(ns: Namespace): string {.gcsafe.} =
  if ns == nil:
    return ""
  let module_name = ns.members.getOrDefault("__module_name__".to_key(), NIL)
  if module_name.kind in {VkString, VkSymbol}:
    return module_name.str
  ns.module_path

proc simple_member_origin(ns: Namespace, name: string, target: Value,
                          kind: SerializationRefKind): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.} =
  if ns == nil or name.len == 0:
    return (false, SerializationOrigin())
  let member = ns.members.getOrDefault(name.to_key(), NIL)
  if member == NIL:
    return (false, SerializationOrigin())
  case kind:
  of SrkClass:
    if member.kind == VkClass and target.kind == VkClass and member.ref.class == target.ref.class:
      return (true, make_origin(kind, namespace_runtime_module_path(ns), name))
  of SrkFunction:
    if member.kind == target.kind and member.raw == target.raw:
      return (true, make_origin(kind, namespace_runtime_module_path(ns), name))
    if member.kind == VkFunction and target.kind == VkFunction and member.ref.fn == target.ref.fn:
      return (true, make_origin(kind, namespace_runtime_module_path(ns), name))
  else:
    discard
  (false, SerializationOrigin())

proc find_live_origin_in_namespace(ns: Namespace, target: Value, module_path: string,
                                   prefix: string, seen: var HashSet[pointer]): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.} =
  if ns == nil:
    return (false, SerializationOrigin())
  let key = cast[pointer](ns)
  if seen.contains(key):
    return (false, SerializationOrigin())
  seen.incl(key)

  for member_key, member_value in ns.members:
    let name = key_to_string(member_key)
    if should_skip_origin_member(name):
      continue
    let path = join_origin_path(prefix, name)

    case target.kind:
    of VkNamespace:
      if member_value.kind == VkNamespace and member_value.ref.ns == target.ref.ns:
        return (true, make_origin(SrkNamespace, module_path, path))
    of VkClass:
      if member_value.kind == VkClass and member_value.ref.class == target.ref.class:
        return (true, make_origin(SrkClass, module_path, path))
    of VkFunction:
      if member_value.kind == VkFunction and member_value.ref.fn == target.ref.fn:
        return (true, make_origin(SrkFunction, module_path, path))
    of VkNativeFn, VkNativeMacro:
      if member_value.raw == target.raw:
        return (true, make_origin(SrkFunction, module_path, path))
    of VkEnum:
      if member_value.kind == VkEnum and member_value.ref.enum_def == target.ref.enum_def:
        return (true, make_origin(SrkEnum, module_path, path))
    of VkEnumMember:
      if member_value.kind == VkEnum:
        for member_name, enum_member in member_value.ref.enum_def.members:
          if enum_member == target.ref.enum_member:
            return (true, make_origin(SrkEnum, module_path, join_origin_path(path, member_name)))
    of VkInstance:
      if member_value.raw == target.raw:
        return (true, make_origin(SrkInstance, module_path, path))
    else:
      discard

    if member_value.kind == VkNamespace:
      let nested = find_live_origin_in_namespace(member_value.ref.ns, target, module_path, path, seen)
      if nested.found:
        return nested
    elif member_value.kind == VkClass and member_value.ref.class != nil and member_value.ref.class.ns != nil:
      let nested = find_live_origin_in_namespace(member_value.ref.class.ns, target, module_path, path, seen)
      if nested.found:
        return nested

  (false, SerializationOrigin())

proc find_live_origin(target: Value): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.} =
  # Last-resort canonicalization for already-live values.
  # This is intentionally only attempted after direct object fields and the
  # per-thread origin registry miss, because it walks reachable namespaces.
  var seen: HashSet[pointer]
  if VM != nil and VM.frame != nil and VM.frame.ns != nil:
    let live = find_live_origin_in_namespace(VM.frame.ns, target,
      namespace_runtime_module_path(VM.frame.ns), "", seen)
    if live.found:
      return live
  if App != NIL and App.kind == VkApplication:
    if App.app.global_ns.kind == VkNamespace:
      let global_live = find_live_origin_in_namespace(App.app.global_ns.ref.ns, target, "", "", seen)
      if global_live.found:
        return global_live
    if App.app.gene_ns.kind == VkNamespace:
      let gene_live = find_live_origin_in_namespace(App.app.gene_ns.ref.ns, target, "", "gene", seen)
      if gene_live.found:
        return gene_live
    if App.app.genex_ns.kind == VkNamespace:
      let genex_live = find_live_origin_in_namespace(App.app.genex_ns.ref.ns, target, "", "genex", seen)
      if genex_live.found:
        return genex_live
  (false, SerializationOrigin())

proc lookup_value_origin(value: Value): tuple[found: bool, origin: SerializationOrigin] {.gcsafe.} =
  case value.kind:
  of VkNamespace:
    if value.ref.ns != nil and value.ref.ns.internal_path.len > 0:
      return (true, make_origin(SrkNamespace, value.ref.ns.module_path, value.ref.ns.internal_path))
  of VkClass:
    return lookup_class_origin(value.ref.class)
  of VkFunction:
    if value.ref.fn != nil and value.ref.fn.internal_path.len > 0:
      return (true, make_origin(SrkFunction, value.ref.fn.module_path, value.ref.fn.internal_path))
    if value.ref.fn != nil and value.ref.fn.name.len > 0:
      if value.ref.fn.ns != nil and value.ref.fn.ns.module_path.len > 0:
        value.ref.fn.module_path = value.ref.fn.ns.module_path
        value.ref.fn.internal_path = join_origin_path(value.ref.fn.ns.internal_path, value.ref.fn.name)
        return (true, make_origin(SrkFunction, value.ref.fn.module_path, value.ref.fn.internal_path))
      if value.ref.fn.ns != nil:
        let direct = simple_member_origin(value.ref.fn.ns, value.ref.fn.name, value, SrkFunction)
        if direct.found:
          value.ref.fn.module_path = direct.origin.module_path
          value.ref.fn.internal_path = direct.origin.internal_path
          return direct
      if VM != nil and VM.frame != nil and VM.frame.ns != nil:
        let current = simple_member_origin(VM.frame.ns, value.ref.fn.name, value, SrkFunction)
        if current.found:
          value.ref.fn.module_path = current.origin.module_path
          value.ref.fn.internal_path = current.origin.internal_path
          return current
  of VkEnum:
    if value.ref.enum_def != nil and value.ref.enum_def.internal_path.len > 0:
      return (true, make_origin(SrkEnum, value.ref.enum_def.module_path, value.ref.enum_def.internal_path))
  of VkEnumMember:
    if value.ref.enum_member != nil and value.ref.enum_member.internal_path.len > 0:
      return (true, make_origin(SrkEnum, value.ref.enum_member.module_path, value.ref.enum_member.internal_path))
  of VkInstance:
    let data = instance_ptr(value)
    if data != nil and data.internal_path.len > 0:
      return (true, make_origin(SrkInstance, data.module_path, data.internal_path))
  else:
    discard

  ensure_value_origin_registry()
  if value_origin_registry.hasKey(value.raw):
    return (true, value_origin_registry[value.raw])

  let live = find_live_origin(value)
  if live.found:
    assign_value_origin(value, live.origin)
    return live
  (false, SerializationOrigin())

proc not_serializable(value: Value, detail = "") {.noreturn, gcsafe.} =
  var msg = "Value of kind " & $value.kind & " is not serializable"
  if detail.len > 0:
    msg &= ": " & detail
  not_allowed(msg)

proc typed_ref_for_value(value: Value): Value {.gcsafe.} =
  let (found, origin) = lookup_value_origin(value)
  if not found or origin.internal_path.len == 0:
    not_serializable(value, "no canonical module/path origin")
  new_typed_ref(origin.kind, origin.internal_path, origin.module_path)

proc typed_ref_for_class(self: Class): Value {.gcsafe.} =
  let (found, origin) = lookup_class_origin(self)
  if not found or origin.internal_path.len == 0:
    not_allowed("Class '" & (if self == nil: "<nil>" else: self.name) &
      "' is not serializable: no canonical module/path origin")
  new_typed_ref(SrkClass, origin.internal_path, origin.module_path)

proc class_to_value(self: Class): Value {.inline, gcsafe.} =
  let r = new_ref(VkClass)
  r.class = self
  r.to_ref_value()

proc resolve_from_namespace(ns: Namespace, path: string): Value {.gcsafe.} =
  if ns == nil or path.len == 0:
    return NIL
  let parts = path.split("/")
  if parts.len == 0:
    return NIL

  var current_ns = ns
  var i = 0
  while i < parts.len:
    let part = parts[i]
    if part.len == 0:
      i.inc()
      continue
    let key = part.to_key()
    if current_ns == nil or not current_ns.members.hasKey(key):
      return NIL
    let current = current_ns.members[key]
    if i == parts.len - 1:
      return current
    case current.kind:
    of VkNamespace:
      current_ns = current.ref.ns
    of VkClass:
      if current.ref.class == nil:
        return NIL
      if i == parts.len - 2:
        let member = current.ref.class.get_member(parts[i + 1].to_key())
        if member != NIL:
          return member
      if current.ref.class.ns == nil:
        return NIL
      current_ns = current.ref.class.ns
    of VkEnum:
      if i == parts.len - 2 and current.ref.enum_def.members.hasKey(parts[i + 1]):
        return current.ref.enum_def.members[parts[i + 1]].to_value()
      return NIL
    else:
      return NIL
    i.inc()
  NIL

proc current_module_namespace(module_path: string): Namespace {.gcsafe.} =
  if module_path.len == 0 or VM == nil or VM.frame == nil or VM.frame.ns == nil:
    return nil
  let module_name = VM.frame.ns.members.getOrDefault("__module_name__".to_key(), NIL)
  if module_name.kind in {VkString, VkSymbol} and module_name.str == module_path:
    return VM.frame.ns
  nil

proc ensure_module_namespace(module_path: string): Namespace {.gcsafe.} =
  if module_path.len == 0:
    return nil
  let current_ns = current_module_namespace(module_path)
  if current_ns != nil:
    return current_ns
  if not serdes_module_loader_hook.isNil:
    {.cast(gcsafe).}:
      return serdes_module_loader_hook(module_path)
  nil

proc resolve_named_reference(module_path, path: string): Value {.gcsafe.} =
  if path.len == 0:
    not_allowed("Serialization reference is missing ^path")

  if module_path.len > 0:
    let module_ns = ensure_module_namespace(module_path)
    if module_ns == nil:
      not_allowed("Module '" & module_path & "' is not available for deserialization")
    let resolved = resolve_from_namespace(module_ns, path)
    if resolved != NIL:
      return resolved
    not_allowed("Serialized reference not found in module '" & module_path & "': " & path)

  result = path_to_value(path)
  if result == NIL:
    not_allowed("Serialized reference not found: " & path)

proc parse_typed_ref(gene: ptr Gene): tuple[module_path: string, path: string] {.gcsafe.} =
  let path_value = gene.props.getOrDefault("path".to_key(), NIL)
  if path_value.kind notin {VkString, VkSymbol}:
    not_allowed("Serialized reference expects string/symbol ^path")
  result.path = path_value.str

  let module_value = gene.props.getOrDefault("module".to_key(), NIL)
  if module_value != NIL:
    if module_value.kind notin {VkString, VkSymbol}:
      not_allowed("Serialized reference expects string/symbol ^module")
    result.module_path = module_value.str

proc resolve_typed_ref(gene: ptr Gene): Value {.gcsafe.} =
  let parsed = parse_typed_ref(gene)
  resolve_named_reference(parsed.module_path, parsed.path)

proc find_serialize_hook(cls: Class): Value =
  if cls == nil:
    return NIL
  for name in [".serialize", "serialize"]:
    let meth = cls.get_method(name)
    if meth != nil:
      return meth.callable
  return NIL

proc find_deserialize_hook(cls: Class): Value =
  if cls == nil:
    return NIL
  for name in [".deserialize", "deserialize"]:
    let meth = cls.get_method(name)
    if meth != nil:
      return meth.callable
  return NIL

proc class_display_name(cls: Class): string {.inline.} =
  if cls == nil or cls.name.len == 0:
    "<nil>"
  else:
    cls.name

proc require_custom_serdes_hooks(cls: Class): tuple[serialize_hook: Value, deserialize_hook: Value] =
  result.serialize_hook = find_serialize_hook(cls)
  if result.serialize_hook == NIL:
    not_allowed("Custom serialization requires class '" & class_display_name(cls) & "' to define serialize")

  result.deserialize_hook = find_deserialize_hook(cls)
  if result.deserialize_hook == NIL:
    not_allowed("Custom serialization requires class '" & class_display_name(cls) & "' to define deserialize")

proc invoke_serialize_hook(hook: Value, value: Value): Value {.gcsafe.} =
  case hook.kind:
  of VkFunction, VkBlock:
    if VM == nil:
      not_allowed("Serialization hook requires an active VM")
    {.cast(gcsafe).}:
      return vm_exec_callable(VM, hook, @[value])
  of VkNativeFn:
    return call_native_fn(hook.ref.native_fn, VM, [value])
  else:
    not_allowed("Serialize hook must be a function or native function")

proc invoke_deserialize_hook(cls: Class, state: Value): tuple[handled: bool, value: Value] {.gcsafe.} =
  let hook = find_deserialize_hook(cls)
  if hook == NIL:
    return (false, NIL)

  let class_val = class_to_value(cls)
  case hook.kind:
  of VkFunction, VkBlock:
    if VM == nil:
      not_allowed("Deserialization hook requires an active VM")
    {.cast(gcsafe).}:
      return (true, vm_exec_callable(VM, hook, @[class_val, state]))
  of VkNativeFn:
    return (true, call_native_fn(hook.ref.native_fn, VM, [class_val, state]))
  else:
    not_allowed("Deserialize hook must be a function or native function")

proc has_direct_value_origin(value: Value): tuple[has_origin: bool, origin: SerializationOrigin] {.gcsafe.} =
  case value.kind:
  of VkNamespace:
    if value.ref.ns != nil and value.ref.ns.internal_path.len > 0:
      return (true, make_origin(SrkNamespace, value.ref.ns.module_path, value.ref.ns.internal_path))
  of VkClass:
    if value.ref.class != nil and value.ref.class.internal_path.len > 0:
      return (true, make_origin(SrkClass, value.ref.class.module_path, value.ref.class.internal_path))
  of VkFunction:
    if value.ref.fn != nil and value.ref.fn.internal_path.len > 0:
      return (true, make_origin(SrkFunction, value.ref.fn.module_path, value.ref.fn.internal_path))
  of VkEnum:
    if value.ref.enum_def != nil and value.ref.enum_def.internal_path.len > 0:
      return (true, make_origin(SrkEnum, value.ref.enum_def.module_path, value.ref.enum_def.internal_path))
  of VkEnumMember:
    if value.ref.enum_member != nil and value.ref.enum_member.internal_path.len > 0:
      return (true, make_origin(SrkEnum, value.ref.enum_member.module_path, value.ref.enum_member.internal_path))
  of VkInstance:
    let data = instance_ptr(value)
    if data != nil and data.internal_path.len > 0:
      return (true, make_origin(SrkInstance, data.module_path, data.internal_path))
  else:
    discard
  (false, SerializationOrigin())

proc tag_value_origin(value: Value, module_path, internal_path: string) {.gcsafe.} =
  if value == NIL or internal_path.len == 0:
    return
  let existing = has_direct_value_origin(value)
  if existing.has_origin:
    register_value_origin(value, existing.origin)
    return
  let kind = case value.kind:
    of VkNamespace: SrkNamespace
    of VkClass: SrkClass
    of VkFunction, VkNativeFn, VkNativeMacro: SrkFunction
    of VkEnum, VkEnumMember: SrkEnum
    of VkInstance: SrkInstance
    else: return
  assign_value_origin(value, make_origin(kind, module_path, internal_path))

proc tag_namespace_serialization_origins*(ns: Namespace, module_path: string, prefix = "") =
  if ns == nil:
    return

  var seen: HashSet[pointer]
  let export_root = ns

  proc walk(current: Namespace, current_prefix: string, tag_self: bool) =
    if current == nil:
      return
    let ns_key = cast[pointer](current)
    if seen.contains(ns_key):
      return
    seen.incl(ns_key)

    if tag_self and current_prefix.len > 0:
      tag_value_origin(current.to_value(), module_path, current_prefix)

    for key, value in current.members:
      let name = key_to_string(key)
      if should_skip_origin_member(name):
        continue
      let path = join_origin_path(current_prefix, name)
      if not namespace_path_is_exported(export_root, path):
        continue
      tag_value_origin(value, module_path, path)
      if value.kind == VkNamespace:
        walk(value.ref.ns, path, true)
      elif value.kind == VkClass and value.ref.class != nil and value.ref.class.ns != nil:
        walk(value.ref.class.ns, path, false)

  walk(ns, prefix, prefix.len > 0)

proc tag_stdlib_serialization_origins*() =
  if App == NIL or App.kind != VkApplication:
    return
  if App.app.global_ns.kind == VkNamespace:
    tag_namespace_serialization_origins(App.app.global_ns.ref.ns, "", "")
  if App.app.gene_ns.kind == VkNamespace:
    tag_namespace_serialization_origins(App.app.gene_ns.ref.ns, "", "gene")
  if App.app.genex_ns.kind == VkNamespace:
    tag_namespace_serialization_origins(App.app.genex_ns.ref.ns, "", "genex")

# Serialize a value into a form that can be stored and later deserialized
proc serialize*(value: Value): Serialization =
  result = Serialization(
    references: initTable[string, Value](),
  )
  result.data = result.serialize(value)

proc serialize*(self: Serialization, value: Value): Value =
  let value = materialize_lazy_tree_value(value)
  case value.kind:
  of VkNil, VkVoid, VkBool, VkInt, VkFloat, VkChar:
    return value
  of VkString, VkSymbol:
    return value
  of VkArray:
    var arr_val = new_array_value(@[], frozen = array_is_frozen(value))
    for item in array_data(value):
      array_data(arr_val).add(self.serialize(item))
    return arr_val
  of VkMap:
    let map = new_map_value(map_is_frozen(value))
    map_data(map) = initTable[Key, Value]()
    for k, v in map_data(value):
      map_data(map)[k] = self.serialize(v)
    return map
  of VkGene:
    let gene = new_gene(self.serialize(value.gene.type), frozen = gene_is_frozen(value))
    for k, v in value.gene.props:
      gene.props[k] = self.serialize(v)
    for child in value.gene.children:
      gene.children.add(self.serialize(child))
    return gene.to_gene_value()
  of VkNamespace, VkClass, VkFunction, VkNativeFn, VkNativeMacro, VkEnum, VkEnumMember:
    return typed_ref_for_value(value)
  of VkInstance:
    let (named, _) = lookup_value_origin(value)
    if named:
      return typed_ref_for_value(value)
    not_serializable(value, "anonymous instances cannot be serialized")
  of VkCustom:
    let cls = value.ref.custom_class
    let hooks = require_custom_serdes_hooks(cls)
    let payload = invoke_serialize_hook(hooks.serialize_hook, value)
    return new_serialized_instance(typed_ref_for_class(cls), self.serialize(payload))
  else:
    not_serializable(value)

# Fast literal checker: primitives, strings/symbols, arrays/maps/genes with literal children
proc is_literal_value*(v: Value): bool {.inline, gcsafe.} =
  var stack: seq[Value] = @[v]
  var seen_arrays: HashSet[ptr ArrayObj]
  var seen_maps: HashSet[ptr MapObj]
  var seen_genes: HashSet[ptr Gene]

  while stack.len > 0:
    let cur = stack.pop()
    case cur.kind:
    of VkVoid, VkNil, VkPlaceholder, VkBool, VkInt, VkFloat, VkChar,
       VkString, VkSymbol, VkComplexSymbol, VkByte, VkBytes, VkBin, VkBin64,
       VkDate, VkDateTime:
      continue
    of VkArray:
      let r = array_ptr(cur)
      if seen_arrays.contains(r): continue
      seen_arrays.incl(r)
      for item in r.arr: stack.add(item)
    of VkMap:
      let r = map_ptr(cur)
      if seen_maps.contains(r): continue
      seen_maps.incl(r)
      for _, val in r.map: stack.add(val)
    of VkGene:
      let gptr = cur.gene
      if seen_genes.contains(gptr): continue
      seen_genes.incl(gptr)
      if gptr.type != NIL:
        stack.add(gptr.type)
      for _, val in gptr.props: stack.add(val)
      for child in gptr.children: stack.add(child)
    else:
      return false
  true

# Serialize only literal values; reject unsupported kinds early.
#
# Thread messaging only supports "literal" values - primitives and containers
# with literal contents. This constraint exists because:
# 1. Functions/closures may reference thread-local state
# 2. Class/instance objects have complex object graphs
# 3. Thread/Future handles are thread-specific
#
# Allowed types: nil, bool, int, float, char, string, symbol, byte, bytes,
#                date, datetime, arrays/maps/genes with literal contents
# Not allowed: functions, classes, instances, threads, futures, namespaces, etc.
proc serialize_literal*(value: Value): Serialization {.gcsafe.} =
  if not is_literal_value(value):
    not_allowed("Thread message payload must be a literal value. Got " & $value.kind &
                ". Allowed: primitives (nil/bool/int/float/char/string/symbol/byte/bytes/date/datetime) " &
                "and containers (array/map/gene) with literal contents. " &
                "Not allowed: functions, classes, instances, threads, futures.")
  serialize(value)

proc deserialize_literal*(s: string): Value {.gcsafe.} =
  deserialize(s)

proc to_path*(self: Class): string =
  let (found, origin) = lookup_class_origin(self)
  if not found:
    not_allowed("Class '" & (if self == nil: "<nil>" else: self.name) & "' has no canonical serialization path")
  origin.internal_path

# A path looks like
# Class C => "pkgP:modM:nsN/C" or just "nsN/C" or "C"
proc to_path*(self: Value): string =
  let (found, origin) = lookup_value_origin(self)
  if not found:
    not_allowed("Value of kind " & $self.kind & " has no canonical serialization path")
  origin.internal_path

proc path_to_value*(path: string): Value =
  if App != NIL and App.kind == VkApplication:
    if path == "gene":
      return App.app.gene_ns
    if path == "genex":
      return App.app.genex_ns
    if path.startsWith("gene/") and App.app.gene_ns.kind == VkNamespace:
      let resolved = resolve_from_namespace(App.app.gene_ns.ref.ns, path["gene/".len .. ^1])
      if resolved != NIL:
        return resolved
    if path.startsWith("genex/") and App.app.genex_ns.kind == VkNamespace:
      let resolved = resolve_from_namespace(App.app.genex_ns.ref.ns, path["genex/".len .. ^1])
      if resolved != NIL:
        return resolved

  if VM != nil and VM.frame != nil and VM.frame.ns != nil:
    let resolved = resolve_from_namespace(VM.frame.ns, path)
    if resolved != NIL:
      return resolved

  if App != NIL and App.kind == VkApplication and App.app.global_ns.kind == VkNamespace:
    let resolved = resolve_from_namespace(App.app.global_ns.ref.ns, path)
    if resolved != NIL:
      return resolved

  not_allowed("path_to_value: not found: " & path)

proc value_to_gene_str*(self: Value): string

proc key_to_string(k: Key): string {.inline, gcsafe.} =
  let symbol_value = cast[Value](k)
  let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
  get_symbol(symbol_index.int)

proc is_tree_structural(value: Value): bool {.inline.} =
  value.kind in {VkMap, VkArray, VkGene}

proc split_tree_selector_path(path: string): seq[string] {.gcsafe.} =
  if '\\' notin path:
    return path.split('/')

  result = @[]
  var part = ""
  var i = 0
  while i < path.len:
    if path[i] == '\\' and i + 1 < path.len and path[i + 1] == '/':
      part.add('/')
      i += 2
    elif path[i] == '/':
      result.add(part)
      part = ""
      inc(i)
    else:
      part.add(path[i])
      inc(i)
  result.add(part)

proc encode_path_segment(segment: string): string =
  encodeUrl(segment, usePlus = false)

proc decode_path_segment(segment: string): string =
  decodeUrl(segment, decodePlus = false)

proc tree_path_key(segments: openArray[string]): string {.gcsafe.} =
  if segments.len == 0:
    return "/"

  var encoded: seq[string] = @[]
  for segment in segments:
    encoded.add(encode_path_segment(segment))
  encoded.join("/")

proc tree_path_display(segments: openArray[string]): string =
  if segments.len == 0:
    return "/"
  "/" & segments.join("/")

proc has_lazy_requests(options: LazyTreeReadOptions): bool {.inline, gcsafe.} =
  options.enabled and options.lazy_nodes.len > 0

proc parse_lazy_selector(selector: Value): seq[string] {.gcsafe.} =
  var parts: seq[string]
  case selector.kind
  of VkComplexSymbol:
    parts = selector.ref.csymbol
  of VkSelector:
    parts = @[""]
    for segment in selector.ref.selector_path:
      case segment.kind
      of VkString, VkSymbol:
        parts.add(segment.str)
      of VkInt:
        parts.add($segment.to_int())
      else:
        not_allowed("read_tree ^lazy selectors only support string, symbol, and integer path segments")
  of VkString, VkSymbol:
    parts = split_tree_selector_path(selector.str)
  else:
    not_allowed("read_tree ^lazy entries must be selectors, strings, or symbols")

  if parts.len > 0 and parts[0] == "self":
    parts[0] = ""

  if parts.len == 0 or parts[0] != "":
    not_allowed("read_tree ^lazy entries must be absolute node selectors")

  if parts.len == 1:
    return @[]
  parts[1 .. ^1]

proc build_tree_read_options(lazy_value: Value): LazyTreeReadOptions {.gcsafe.} =
  result.lazy_nodes = initHashSet[string]()
  if lazy_value.kind == VkNil:
    return
  if lazy_value.kind != VkArray:
    not_allowed("read_tree ^lazy expects an array")

  result.enabled = true
  for selector in array_data(lazy_value):
    let segments = parse_lazy_selector(selector)
    result.lazy_nodes.incl(tree_path_key(segments))

proc materialize_lazy_tree_data(data: CustomValue): Value {.gcsafe.}

proc make_lazy_tree_value(path: string, source_kind: LazyTreeSourceKind, node_segments: seq[string], options: LazyTreeReadOptions): Value {.gcsafe.} =
  if lazy_tree_value_class.is_nil:
    not_allowed("Lazy tree class is not initialized")
  let data = LazyTreeValueData(
    path: path,
    source_kind: source_kind,
    node_segments: node_segments,
    options: options,
    materialized: NIL,
    materialized_loaded: false,
  )
  data.materialize_hook = materialize_lazy_tree_data
  new_custom_value(lazy_tree_value_class, data)

proc materialize_lazy_tree_value*(value: Value): Value {.gcsafe.} =
  if not is_lazy_tree_value(value):
    return value
  let data = LazyTreeValueData(value.ref.custom_data)
  if data.materialized_loaded:
    return data.materialized
  let materialized = data.materialize_hook(data)
  if not data.materialized_loaded:
    data.materialized = materialized
    data.materialized_loaded = true
  data.materialized

proc materialize_lazy_tree_deep*(value: Value): Value {.gcsafe.} =
  let current = materialize_lazy_tree_value(value)
  case current.kind
  of VkArray:
    result = new_array_value(@[], frozen = array_is_frozen(current))
    for item in array_data(current):
      array_data(result).add(materialize_lazy_tree_deep(item))
  of VkMap:
    result = new_map_value(map_is_frozen(current))
    for k, v in map_data(current):
      map_data(result)[k] = materialize_lazy_tree_deep(v)
  of VkGene:
    let gene = new_gene(materialize_lazy_tree_deep(current.gene.type), frozen = gene_is_frozen(current))
    for k, v in current.gene.props:
      gene.props[k] = materialize_lazy_tree_deep(v)
    for child in current.gene.children:
      gene.children.add(materialize_lazy_tree_deep(child))
    result = gene.to_gene_value()
  else:
    result = current

proc payload_to_serialized_text(payload: Value): string =
  "(gene/serialization " & value_to_gene_str(payload) & ")"

proc value_to_serialized_text(value: Value): string =
  payload_to_serialized_text(serialize(value).data)

proc tree_serialized_hash(value: Value): Hash

proc mix_tree_hash(result: var Hash, marker: string) {.inline.} =
  result = result !& hash(marker)

proc tree_serialized_hash(value: Value): Hash =
  let value = materialize_lazy_tree_value(value)
  var result_hash: Hash = 0
  case value.kind:
  of VkNil:
    result_hash.mix_tree_hash("nil")
  of VkBool:
    result_hash.mix_tree_hash(if value == TRUE: "true" else: "false")
  of VkInt:
    result_hash.mix_tree_hash("int")
    result_hash = result_hash !& hash(value.to_int())
  of VkFloat:
    result_hash.mix_tree_hash("float")
    result_hash = result_hash !& hash(value.to_float())
  of VkChar:
    result_hash.mix_tree_hash("char")
    result_hash = result_hash !& hash((value.raw and 0xFF).int)
  of VkString:
    result_hash.mix_tree_hash("string")
    result_hash = result_hash !& hash(value.str)
  of VkSymbol:
    result_hash.mix_tree_hash("symbol")
    result_hash = result_hash !& hash(value.str)
  of VkArray:
    result_hash.mix_tree_hash("array")
    for item in array_data(value):
      result_hash = result_hash !& tree_serialized_hash(item)
  of VkMap:
    result_hash.mix_tree_hash("map")
    for k, v in map_data(value):
      result_hash = result_hash !& hash(key_to_string(k))
      result_hash = result_hash !& tree_serialized_hash(v)
  of VkGene:
    result_hash.mix_tree_hash("gene")
    result_hash = result_hash !& tree_serialized_hash(value.gene.type)
    for k, v in value.gene.props:
      result_hash = result_hash !& hash(key_to_string(k))
      result_hash = result_hash !& tree_serialized_hash(v)
    for child in value.gene.children:
      result_hash = result_hash !& tree_serialized_hash(child)
  of VkNamespace, VkClass, VkFunction, VkNativeFn, VkNativeMacro, VkEnum, VkEnumMember:
    let (_, origin) = lookup_value_origin(value)
    let typed_ref = typed_ref_for_value(value)
    result_hash.mix_tree_hash(ref_kind_name(origin.kind))
    result_hash = result_hash !& hash(value_to_gene_str(typed_ref))
  of VkInstance:
    let (named, _) = lookup_value_origin(value)
    if named:
      let typed_ref = typed_ref_for_value(value)
      result_hash.mix_tree_hash("InstanceRef")
      result_hash = result_hash !& hash(value_to_gene_str(typed_ref))
    else:
      result_hash.mix_tree_hash("Instance")
      result_hash = result_hash !& hash(value_to_gene_str(typed_ref_for_class(value.instance_class)))
      for k, v in value.instance_props:
        result_hash = result_hash !& hash(key_to_string(k))
        result_hash = result_hash !& tree_serialized_hash(v)
  else:
    not_serializable(value)
  !$result_hash

proc add_directory_node(options: var TreeWriteOptions, segments: openArray[string]) =
  options.directory_nodes.incl(tree_path_key(segments))

proc should_write_dir(options: TreeWriteOptions, segments: openArray[string]): bool =
  options.directory_nodes.contains(tree_path_key(segments))

proc parse_tree_selector(selector: Value): seq[string] =
  var parts: seq[string]
  case selector.kind
  of VkComplexSymbol:
    parts = selector.ref.csymbol
  of VkSelector:
    parts = @[""]
    for segment in selector.ref.selector_path:
      case segment.kind
      of VkString, VkSymbol:
        parts.add(segment.str)
      of VkInt:
        parts.add($segment.to_int())
      else:
        not_allowed("write_tree ^separate selectors only support string, symbol, and integer path segments")
  of VkString, VkSymbol:
    parts = split_tree_selector_path(selector.str)
  else:
    not_allowed("write_tree ^separate entries must be selectors, strings, or symbols")

  if parts.len > 0 and parts[0] == "self":
    parts[0] = ""

  if parts.len < 2 or parts[0] != "" or parts[^1] != "*":
    not_allowed("write_tree ^separate entries must be absolute child selectors ending with /*")

  if parts.len == 2:
    return @[]
  parts[1 .. ^2]

proc build_tree_write_options(separate_value: Value): TreeWriteOptions =
  result.directory_nodes = initHashSet[string]()
  if separate_value == NIL:
    return
  if separate_value.kind != VkArray:
    not_allowed("write_tree ^separate expects an array")

  for selector in array_data(separate_value):
    let parent_segments = parse_tree_selector(selector)
    for prefix_len in 0 .. parent_segments.len:
      result.add_directory_node(parent_segments[0 ..< prefix_len])

proc ensure_parent_dir(path: string) =
  let parent = parentDir(path)
  if parent.len > 0 and parent != ".":
    createDir(parent)

proc write_serialized_file(path: string, value: Value) =
  ensure_parent_dir(path)
  let temp_path = path & ".tmp"
  if fileExists(temp_path):
    removeFile(temp_path)
  writeFile(temp_path, value_to_serialized_text(value))
  moveFile(temp_path, path)

proc read_serialized_file(path: string): Value {.gcsafe.} =
  count_tree_serialized_file_read()
  deserialize(readFile(path))

proc remove_tree_dir(path: string) =
  if fileExists(path):
    removeFile(path)
    return
  if not dirExists(path):
    return

  for kind, child in walkDir(path):
    case kind
    of pcFile, pcLinkToFile:
      removeFile(child)
    of pcDir:
      remove_tree_dir(child)
    of pcLinkToDir:
      removeDir(child)
  removeDir(path)

proc remove_tree_base(path: string) =
  let file_path = path & ".gene"
  if fileExists(file_path):
    removeFile(file_path)
  if dirExists(path):
    remove_tree_dir(path)

proc write_tree_node(path: string, value: Value, node_segments: seq[string], options: TreeWriteOptions, known_map = false)
proc write_tree_dir(path: string, value: Value, node_segments: seq[string], options: TreeWriteOptions, known_map = false)
proc read_tree_path(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.}
proc read_tree_root_path(path: string, options: LazyTreeReadOptions): Value {.gcsafe.}
proc read_known_map_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.}
proc read_array_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.}
proc read_gene_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.}
proc list_tree_dir_entries(path: string): seq[(PathComponent, string)] {.gcsafe.}
proc resolve_tree_named_child(path: string, child_name: string, child_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.}
proc can_decode_as_array_dir(path: string): bool {.gcsafe.}

proc make_array_child_id(value: Value, used_ids: var Table[string, int]): string =
  let base = "v" & toHex(cast[uint64](tree_serialized_hash(value)), 12)
  let next_count = used_ids.getOrDefault(base, 0) + 1
  used_ids[base] = next_count
  if next_count == 1:
    base
  else:
    base & "-" & $next_count

proc write_map_dir(path: string, map_value: Value, node_segments: seq[string], options: TreeWriteOptions, allow_root_markers: bool) =
  createDir(path)
  var keys: seq[string] = @[]
  var key_values = initTable[string, Value]()
  for k, v in map_data(map_value):
    let key_name = key_to_string(k)
    if not allow_root_markers and key_name == TreeGeneTypeName:
      not_allowed("Exploded generic map roots cannot use reserved entry name: " & key_name)
    keys.add(key_name)
    key_values[key_name] = v

  keys.sort()
  for key_name in keys:
    let child = key_values[key_name]
    let encoded = encode_path_segment(key_name)
    let child_segments = node_segments & @[key_name]
    write_tree_node(joinPath(path, encoded), child, child_segments, options, false)

proc write_array_dir(path: string, array_value: Value, node_segments: seq[string], options: TreeWriteOptions) =
  createDir(path)
  var order = new_array_value()
  var used_ids = initTable[string, int]()
  for index, child in array_data(array_value):
    let child_id = make_array_child_id(child, used_ids)
    array_data(order).add(child_id.to_value())
    let child_segments = node_segments & @[$index]
    write_tree_node(joinPath(path, child_id), child, child_segments, options, false)
  write_serialized_file(joinPath(path, TreeArrayName & ".gene"), order)

proc write_gene_dir(path: string, gene_value: Value, node_segments: seq[string], options: TreeWriteOptions) =
  createDir(path)
  let type_segments = node_segments & @[TreeGeneTypeName]
  write_tree_node(joinPath(path, TreeGeneTypeName), gene_value.gene.type, type_segments, options, false)

  let props_segments = node_segments & @[TreeGenePropsName]
  if gene_value.gene.props.len > 0 or should_write_dir(options, props_segments):
    let props_path = joinPath(path, TreeGenePropsName)
    var props_value = new_map_value()
    map_data(props_value) = initTable[Key, Value]()
    for k, v in gene_value.gene.props:
      map_data(props_value)[k] = v
    write_map_dir(props_path, props_value, props_segments, options, true)

  let children_segments = node_segments & @[TreeGeneChildrenName]
  if gene_value.gene.children.len > 0 or should_write_dir(options, children_segments):
    let children_path = joinPath(path, TreeGeneChildrenName)
    var children_value = new_array_value()
    for child in gene_value.gene.children:
      array_data(children_value).add(child)
    write_array_dir(children_path, children_value, children_segments, options)

proc write_tree_node(path: string, value: Value, node_segments: seq[string], options: TreeWriteOptions, known_map = false) =
  let value = materialize_lazy_tree_deep(value)
  remove_tree_base(path)

  if should_write_dir(options, node_segments):
    if not is_tree_structural(value):
      not_allowed("write_tree ^separate targets a non-structural value at " & tree_path_display(node_segments))
    write_tree_dir(path, value, node_segments, options, known_map)
  else:
    write_serialized_file(path & ".gene", value)

proc write_tree_dir(path: string, value: Value, node_segments: seq[string], options: TreeWriteOptions, known_map = false) =
  case value.kind
  of VkMap:
    write_map_dir(path, value, node_segments, options, known_map)
  of VkArray:
    write_array_dir(path, value, node_segments, options)
  of VkGene:
    write_gene_dir(path, value, node_segments, options)
  else:
    not_allowed("Directory tree serialization requires a Map, Array, or Gene root")

proc list_tree_dir_entries(path: string): seq[(PathComponent, string)] {.gcsafe.} =
  count_tree_dir_listing()
  for kind, entry in walkDir(path, relative = true):
    result.add((kind, entry))
  result.sort(proc(a, b: (PathComponent, string)): int = cmp(a[1], b[1]))

proc resolve_tree_named_child(path: string, child_name: string, child_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.} =
  let inline_path = joinPath(path, child_name & ".gene")
  let dir_path = joinPath(path, child_name)
  let has_inline = fileExists(inline_path)
  let has_dir = dirExists(dir_path)
  if has_inline and has_dir:
    not_allowed("Filesystem tree child is ambiguous, both file and directory exist: " & joinPath(path, child_name))
  if has_inline:
    if shallow:
      return make_lazy_tree_value(inline_path, LtsFile, child_segments, options)
    return read_serialized_file(inline_path)
  if has_dir:
    if shallow:
      return make_lazy_tree_value(dir_path, LtsDirectory, child_segments, options)
    return read_tree_dir(dir_path, child_segments, options, false)
  not_allowed("Filesystem tree child not found: " & joinPath(path, child_name))

proc read_known_map_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.} =
  result = new_map_value()
  map_data(result) = initTable[Key, Value]()
  for (kind, entry) in list_tree_dir_entries(path):
    case kind
    of pcFile:
      if not entry.endsWith(".gene"):
        continue
      let decoded = decode_path_segment(splitFile(entry).name)
      let child_segments = node_segments & @[decoded]
      if shallow:
        map_data(result)[decoded.to_key()] = make_lazy_tree_value(joinPath(path, entry), LtsFile, child_segments, options)
      else:
        map_data(result)[decoded.to_key()] = read_serialized_file(joinPath(path, entry))
    of pcDir:
      let decoded = decode_path_segment(entry)
      let child_segments = node_segments & @[decoded]
      if shallow:
        map_data(result)[decoded.to_key()] = make_lazy_tree_value(joinPath(path, entry), LtsDirectory, child_segments, options)
      else:
        map_data(result)[decoded.to_key()] = read_tree_dir(joinPath(path, entry), child_segments, options, false)
    else:
      discard

proc can_decode_as_array_dir(path: string): bool {.gcsafe.} =
  let manifest_path = joinPath(path, TreeArrayName & ".gene")
  if not fileExists(manifest_path):
    return false

  let manifest = read_serialized_file(manifest_path)
  if manifest.kind != VkArray:
    return false

  var child_ids = initHashSet[string]()
  for item in array_data(manifest):
    if item.kind != VkString:
      return false
    let child_id = item.str
    if child_ids.contains(child_id):
      return false
    child_ids.incl(child_id)

  for (kind, entry) in list_tree_dir_entries(path):
    case kind
    of pcFile:
      if not entry.endsWith(".gene"):
        continue
      let entry_name = splitFile(entry).name
      if entry_name == TreeArrayName:
        continue
      if not child_ids.contains(entry_name):
        return false
    of pcDir:
      if not child_ids.contains(entry):
        return false
    else:
      discard

  for child_id in child_ids:
    let inline_path = joinPath(path, child_id & ".gene")
    let dir_path = joinPath(path, child_id)
    let has_inline = fileExists(inline_path)
    let has_dir = dirExists(dir_path)
    if has_inline == has_dir:
      return false

  true

proc read_array_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.} =
  let order_path = joinPath(path, TreeArrayName & ".gene")
  if not fileExists(order_path):
    not_allowed("Exploded array is missing " & TreeArrayName & ".gene: " & path)

  let order = read_serialized_file(order_path)
  if order.kind != VkArray:
    not_allowed(TreeArrayName & ".gene must contain an array of child ids")

  result = new_array_value()
  for index, item in array_data(order):
    if item.kind != VkString:
      not_allowed(TreeArrayName & ".gene child ids must be strings")
    let child_id = item.str
    let inline_path = joinPath(path, child_id & ".gene")
    let dir_path = joinPath(path, child_id)
    let child_segments = node_segments & @[$index]
    if fileExists(inline_path):
      if shallow:
        array_data(result).add(make_lazy_tree_value(inline_path, LtsFile, child_segments, options))
      else:
        array_data(result).add(read_serialized_file(inline_path))
    elif dirExists(dir_path):
      if shallow:
        array_data(result).add(make_lazy_tree_value(dir_path, LtsDirectory, child_segments, options))
      else:
        array_data(result).add(read_tree_dir(dir_path, child_segments, options, false))
    else:
      not_allowed("Missing exploded array child: " & child_id)

proc read_gene_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.} =
  let type_file_path = joinPath(path, TreeGeneTypeName & ".gene")
  let type_dir_path = joinPath(path, TreeGeneTypeName)
  if not fileExists(type_file_path) and not dirExists(type_dir_path):
    not_allowed("Exploded Gene value is missing " & TreeGeneTypeName & ": " & path)

  let type_segments = node_segments & @[TreeGeneTypeName]
  let gene = new_gene(resolve_tree_named_child(path, TreeGeneTypeName, type_segments, options, shallow))

  let props_path = joinPath(path, TreeGenePropsName)
  if dirExists(props_path):
    let props_segments = node_segments & @[TreeGenePropsName]
    let props_value = read_known_map_dir(props_path, props_segments, options, shallow)
    for k, v in map_data(props_value):
      gene.props[k] = v

  let children_path = joinPath(path, TreeGeneChildrenName)
  if dirExists(children_path):
    let children_segments = node_segments & @[TreeGeneChildrenName]
    let children_value = read_array_dir(children_path, children_segments, options, shallow)
    for child in array_data(children_value):
      gene.children.add(child)

  gene.to_gene_value()

proc read_tree_dir(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.} =
  let type_file_path = joinPath(path, TreeGeneTypeName & ".gene")
  let type_dir_path = joinPath(path, TreeGeneTypeName)
  if fileExists(type_file_path) or dirExists(type_dir_path):
    return read_gene_dir(path, node_segments, options, shallow)

  if can_decode_as_array_dir(path):
    return read_array_dir(path, node_segments, options, shallow)

  read_known_map_dir(path, node_segments, options, shallow)

proc read_tree_path(path: string, node_segments: seq[string], options: LazyTreeReadOptions, shallow: bool): Value {.gcsafe.} =
  if fileExists(path):
    if shallow:
      return make_lazy_tree_value(path, LtsFile, node_segments, options)
    return read_serialized_file(path)
  if dirExists(path):
    if shallow:
      return make_lazy_tree_value(path, LtsDirectory, node_segments, options)
    return read_tree_dir(path, node_segments, options, false)
  not_allowed("Filesystem tree path not found: " & path)

proc read_tree_root_path(path: string, options: LazyTreeReadOptions): Value {.gcsafe.} =
  if path.endsWith(".gene"):
    if options.lazy_nodes.contains(tree_path_key(@[])):
      return make_lazy_tree_value(path, LtsFile, @[], options)
    return read_tree_path(path, @[], options, false)

  let inline_path = path & ".gene"
  let has_inline = fileExists(inline_path)
  let has_dir = dirExists(path)

  if has_inline and has_dir:
    not_allowed("Filesystem tree root is ambiguous, both file and directory exist: " & path)
  if has_inline:
    if options.lazy_nodes.contains(tree_path_key(@[])):
      return make_lazy_tree_value(inline_path, LtsFile, @[], options)
    return read_serialized_file(inline_path)
  if has_dir:
    return read_tree_dir(path, @[], options, options.enabled)
  read_tree_path(path, @[], options, false)

proc materialize_lazy_tree_data(data: CustomValue): Value {.gcsafe.} =
  let lazy_data = LazyTreeValueData(data)
  if lazy_data.materialized_loaded:
    return lazy_data.materialized

  case lazy_data.source_kind
  of LtsFile:
    lazy_data.materialized = read_serialized_file(lazy_data.path)
  of LtsDirectory:
    lazy_data.materialized = read_tree_dir(lazy_data.path, lazy_data.node_segments, lazy_data.options, true)
  lazy_data.materialized_loaded = true

  lazy_data.materialized

proc to_s*(self: Serialization): string =
  result = payload_to_serialized_text(self.data)

proc value_to_gene_str*(self: Value): string =
  let self = materialize_lazy_tree_value(self)
  case self.kind:
  of VkNil:
    result = "nil"
  of VkVoid:
    result = "void"
  of VkBool:
    result = if self == TRUE: "true" else: "false"
  of VkInt:
    result = $self.to_int()
  of VkFloat:
    result = $self.to_float()
  of VkChar:
    # Extract char from NaN-boxed value
    result = "'" & $chr((self.raw and 0xFF).int) & "'"
  of VkString:
    result = json.escapeJson(self.str)
  of VkSymbol:
    result = self.str
  of VkArray:
    result = if array_is_frozen(self): "#[" else: "["
    for i, v in array_data(self):
      if i > 0:
        result &= " "
      result &= value_to_gene_str(v)
    result &= "]"
  of VkMap:
    result = if map_is_frozen(self): "#{" else: "{"
    var first = true
    for k, v in map_data(self):
      if not first:
        result &= " "
      # k is a Key (distinct int64), which is a packed symbol value
      # Extract the symbol index from the packed value
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      let key_str = get_symbol(symbol_index.int)
      result &= "^" & key_str
      result &= " "
      result &= value_to_gene_str(v)
      first = false
    result &= "}"
  of VkGene:
    result = if gene_is_frozen(self): "#(" else: "("
    result &= value_to_gene_str(self.gene.type)
    # Add properties
    for k, v in self.gene.props:
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      result &= " ^" & get_symbol(symbol_index.int) & " " & value_to_gene_str(v)
    # Add children
    for child in self.gene.children:
      result &= " " & value_to_gene_str(child)
    result &= ")"
  else:
    result = $self  # Fallback to default string representation

#################### Deserialization #############

proc deserialize*(self: Serialization, value: Value): Value {.gcsafe.}

proc deref*(self: Serialization, s: string): Value =
  path_to_value(s)

proc deserialize*(s: string): Value =
  var ser = Serialization(
    references: initTable[string, Value](),
  )
  ser.deserialize(read_all(s)[0])

proc deserialize*(self: Serialization, value: Value): Value =
  case value.kind:
  of VkGene:
    var type_str: string
    if value.gene.type.kind == VkSymbol:
      type_str = value.gene.type.str
    elif value.gene.type.kind == VkComplexSymbol:
      type_str = value.gene.type.ref.csymbol.join("/")
    else:
      let gene = new_gene(self.deserialize(value.gene.type), frozen = gene_is_frozen(value))
      for k, v in value.gene.props:
        gene.props[k] = self.deserialize(v)
      for child in value.gene.children:
        gene.children.add(self.deserialize(child))
      return gene.to_gene_value()

    case type_str:
    of "gene/serialization":
      if value.gene.children.len > 0:
        return self.deserialize(value.gene.children[0])
      else:
        return NIL
    of "NamespaceRef", "ClassRef", "FunctionRef", "EnumRef", "InstanceRef":
      return resolve_typed_ref(value.gene)
    of "gene/ref":
      if value.gene.children.len > 0:
        return self.deref(value.gene.children[0].str)
      else:
        return NIL
    of "Instance":
      if value.gene.children.len < 2:
        not_allowed("Instance expects a class reference and payload")

      let class_ref = self.deserialize(value.gene.children[0])
      if class_ref.kind != VkClass:
        not_allowed("Instance expects a class reference")

      let cls = class_ref.ref.class
      let hooks = require_custom_serdes_hooks(cls)
      let state = self.deserialize(value.gene.children[1])
      let class_val = class_to_value(cls)
      var restored: Value
      case hooks.deserialize_hook.kind:
      of VkFunction, VkBlock:
        if VM == nil:
          not_allowed("Deserialization hook requires an active VM")
        {.cast(gcsafe).}:
          restored = vm_exec_callable(VM, hooks.deserialize_hook, @[class_val, state])
      of VkNativeFn:
        restored = call_native_fn(hooks.deserialize_hook.ref.native_fn, VM, [class_val, state])
      else:
        not_allowed("Deserialize hook must be a function or native function")

      if restored.kind != VkCustom:
        not_allowed("Instance deserialize hook must return a custom value")
      if restored.ref.custom_class != cls:
        not_allowed("Instance deserialize hook returned custom value of unexpected class")
      return restored
    of "gene/instance":
      not_allowed("Legacy anonymous instance serialization is not supported")
    else:
      let gene = new_gene(self.deserialize(value.gene.type), frozen = gene_is_frozen(value))
      for k, v in value.gene.props:
        gene.props[k] = self.deserialize(v)
      for child in value.gene.children:
        gene.children.add(self.deserialize(child))
      return gene.to_gene_value()
  else:
    return value

# VM integration functions
proc resolve_symbol_in_caller(caller_frame: Frame, name: string): Value =
  let key = name.to_key()

  if caller_frame != nil and caller_frame.scope != nil and caller_frame.scope.tracker != nil:
    let found = caller_frame.scope.tracker.locate(key)
    if found.local_index >= 0:
      var scope = caller_frame.scope
      var parent_index = found.parent_index
      while parent_index > 0:
        parent_index.dec()
        scope = scope.parent
      if scope != nil and found.local_index < scope.members.len:
        return scope.members[found.local_index]

  if caller_frame != nil and caller_frame.ns != nil:
    let ns_value = caller_frame.ns[key]
    if ns_value != NIL:
      return ns_value

  let global_value = App.app.global_ns.ref.ns.members.getOrDefault(key, NIL)
  if global_value != NIL:
    return global_value

  App.app.gene_ns.ref.ns.members.getOrDefault(key, NIL)

proc eval_in_caller_context(vm: ptr VirtualMachine, expr: Value, caller_frame: Frame): Value =
  discard vm
  case expr.kind
  of VkString, VkInt, VkFloat, VkBool, VkNil, VkChar, VkComplexSymbol:
    return expr
  of VkSymbol:
    let resolved = resolve_symbol_in_caller(caller_frame, expr.str)
    if resolved == NIL:
      not_allowed("Unknown symbol in caller context: " & expr.str)
    return resolved
  of VkArray:
    result = new_array_value(@[], frozen = array_is_frozen(expr))
    for item in array_data(expr):
      array_data(result).add(eval_in_caller_context(vm, item, caller_frame))
  of VkMap:
    result = new_map_value(map_is_frozen(expr))
    for k, v in map_data(expr):
      map_data(result)[k] = eval_in_caller_context(vm, v, caller_frame)
  of VkGene:
    let gene = new_gene(eval_in_caller_context(vm, expr.gene.type, caller_frame), frozen = gene_is_frozen(expr))
    for k, v in expr.gene.props:
      gene.props[k] = eval_in_caller_context(vm, v, caller_frame)
    for child in expr.gene.children:
      gene.children.add(eval_in_caller_context(vm, child, caller_frame))
    return gene.to_gene_value()
  of VkQuote:
    return expr.ref.quote
  else:
    not_allowed("write_tree macro arguments must be literals or symbols")

proc write_tree_root(path: string, value: Value, options: TreeWriteOptions) =
  let value = materialize_lazy_tree_deep(value)
  if path.endsWith(".gene"):
    if options.directory_nodes.len > 0:
      not_allowed("write_tree cannot use a .gene path when ^separate requires directories")
    write_serialized_file(path, value)
  else:
    remove_tree_base(path)
    if should_write_dir(options, @[]):
      if not is_tree_structural(value):
        not_allowed("write_tree ^separate targets a non-structural root value")
      write_tree_dir(path, value, @[], options, false)
    else:
      write_serialized_file(path & ".gene", value)

proc lazy_tree_class_ref(value: Value): Class {.gcsafe.} =
  proc class_value_ref(class_value: Value): Class =
    if class_value.kind == VkClass:
      class_value.ref.class
    else:
      nil

  case value.kind
  of VkNil:
    class_value_ref(App.app.nil_class)
  of VkBool:
    class_value_ref(App.app.bool_class)
  of VkInt:
    class_value_ref(App.app.int_class)
  of VkFloat:
    class_value_ref(App.app.float_class)
  of VkChar:
    class_value_ref(App.app.char_class)
  of VkString:
    class_value_ref(App.app.string_class)
  of VkSymbol:
    class_value_ref(App.app.symbol_class)
  of VkComplexSymbol:
    class_value_ref(App.app.complex_symbol_class)
  of VkArray:
    class_value_ref(App.app.array_class)
  of VkMap:
    class_value_ref(App.app.map_class)
  of VkGene:
    class_value_ref(App.app.gene_class)
  of VkRegex:
    class_value_ref(App.app.regex_class)
  of VkDate:
    class_value_ref(App.app.date_class)
  of VkDateTime:
    class_value_ref(App.app.datetime_class)
  of VkSet:
    class_value_ref(if App.app.hash_set_class.kind == VkClass: App.app.hash_set_class else: App.app.object_class)
  of VkFuture:
    class_value_ref(if App.app.future_class.kind == VkClass: App.app.future_class else: App.app.object_class)
  of VkGenerator:
    class_value_ref(if App.app.generator_class.kind == VkClass: App.app.generator_class else: App.app.object_class)
  of VkNamespace:
    class_value_ref(App.app.namespace_class)
  of VkClass:
    class_value_ref(App.app.class_class)
  of VkInstance:
    value.instance_class
  of VkCustom:
    value.ref.custom_class
  of VkSelector:
    class_value_ref(App.app.selector_class)
  else:
    class_value_ref(App.app.object_class)

proc delegate_lazy_tree_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool, method_name: string): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) < 1:
    not_allowed("Lazy tree method requires self")

  let self_value = get_positional_arg(args, 0, has_keyword_args)
  let actual = materialize_lazy_tree_value(self_value)
  let actual_class = lazy_tree_class_ref(actual)
  if actual_class == nil:
    not_allowed("Lazy tree method dispatch requires a concrete class")

  let meth = actual_class.get_method(method_name)
  if meth == nil or meth.callable.kind notin {VkNativeFn, VkNativeMethod}:
    not_allowed("Lazy tree method '" & method_name & "' is not available on " & $actual.kind)

  var call_args = newSeq[Value](arg_count)
  if has_keyword_args:
    call_args[0] = args[0]
    if arg_count > 1:
      call_args[1] = actual
    for i in 2..<arg_count:
      call_args[i] = args[i]
  else:
    if arg_count > 0:
      call_args[0] = actual
    for i in 1..<arg_count:
      call_args[i] = args[i]

  case meth.callable.kind
  of VkNativeFn:
    return call_native_fn(meth.callable.ref.native_fn, vm, call_args, has_keyword_args)
  of VkNativeMethod:
    return call_native_fn(meth.callable.ref.native_method, vm, call_args, has_keyword_args)
  else:
    not_allowed("Lazy tree method '" & method_name & "' must be native")

proc init_lazy_tree_value_class() =
  if not lazy_tree_value_class.is_nil:
    return

  lazy_tree_value_class = new_class("LazyTreeValue", App.app.object_class.ref.class)

  template def_lazy_delegate(method_name: string, proc_name: untyped) =
    proc proc_name(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
      delegate_lazy_tree_method(vm, args, arg_count, has_keyword_args, method_name)
    lazy_tree_value_class.def_native_method(method_name, proc_name)

  def_lazy_delegate("to_s", lazy_tree_to_s)
  def_lazy_delegate("class", lazy_tree_class)
  def_lazy_delegate("is", lazy_tree_is)
  def_lazy_delegate("iter", lazy_tree_iter)
  def_lazy_delegate("get", lazy_tree_get)
  def_lazy_delegate("set", lazy_tree_set)
  def_lazy_delegate("contains", lazy_tree_contains)
  def_lazy_delegate("has", lazy_tree_has)
  def_lazy_delegate("size", lazy_tree_size)
  def_lazy_delegate("length", lazy_tree_length)
  def_lazy_delegate("keys", lazy_tree_keys)
  def_lazy_delegate("values", lazy_tree_values)
  def_lazy_delegate("each", lazy_tree_each)
  def_lazy_delegate("map", lazy_tree_map)
  def_lazy_delegate("filter", lazy_tree_filter)
  def_lazy_delegate("reduce", lazy_tree_reduce)
  def_lazy_delegate("pairs", lazy_tree_pairs)
  def_lazy_delegate("empty", lazy_tree_empty)
  def_lazy_delegate("clear", lazy_tree_clear)
  def_lazy_delegate("del", lazy_tree_del)
  def_lazy_delegate("merge", lazy_tree_merge)
  def_lazy_delegate("add", lazy_tree_add)
  def_lazy_delegate("append", lazy_tree_append)
  def_lazy_delegate("push", lazy_tree_push)
  def_lazy_delegate("pop", lazy_tree_pop)
  def_lazy_delegate("first", lazy_tree_first)
  def_lazy_delegate("last", lazy_tree_last)
  def_lazy_delegate("slice", lazy_tree_slice)
  def_lazy_delegate("index_of", lazy_tree_index_of)
  def_lazy_delegate("join", lazy_tree_join)
  def_lazy_delegate("take", lazy_tree_take)
  def_lazy_delegate("skip", lazy_tree_skip)
  def_lazy_delegate("find", lazy_tree_find)
  def_lazy_delegate("any", lazy_tree_any)
  def_lazy_delegate("all", lazy_tree_all)
  def_lazy_delegate("zip", lazy_tree_zip)
  def_lazy_delegate("reverse", lazy_tree_reverse)
  def_lazy_delegate("sort", lazy_tree_sort)
  def_lazy_delegate("to_map", lazy_tree_to_map)
  def_lazy_delegate("to_json", lazy_tree_to_json)
  def_lazy_delegate("type", lazy_tree_type)
  def_lazy_delegate("props", lazy_tree_props)
  def_lazy_delegate("children", lazy_tree_children)
  def_lazy_delegate("genetype", lazy_tree_genetype)
  def_lazy_delegate("set_genetype", lazy_tree_set_genetype)

proc vm_serialize(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if arg_count != 1:
      not_allowed("serialize expects 1 argument")

    let value = materialize_lazy_tree_deep(get_positional_arg(args, 0, has_keyword_args))
    return value_to_serialized_text(value).to_value()

proc vm_deserialize(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if arg_count != 1:
      not_allowed("deserialize expects 1 argument")

    let s = get_positional_arg(args, 0, has_keyword_args).str
    return deserialize(s)

proc vm_write_tree_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    when defined(gene_wasm):
      not_allowed("write_tree is not supported in gene_wasm")
    else:
      if gene_value.kind != VkGene or gene_value.gene.children.len != 2:
        not_allowed("write_tree expects 2 arguments")

      let path_arg = eval_in_caller_context(vm, gene_value.gene.children[0], caller_frame)
      if path_arg.kind != VkString:
        not_allowed("write_tree expects a string path")

      let value = eval_in_caller_context(vm, gene_value.gene.children[1], caller_frame)
      let separate_value = gene_value.gene.props.getOrDefault("separate".to_key(), NIL)
      let options = build_tree_write_options(separate_value)
      write_tree_root(path_arg.str, value, options)
      NIL

proc vm_read_tree_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    when defined(gene_wasm):
      not_allowed("read_tree is not supported in gene_wasm")
    else:
      if gene_value.kind != VkGene or gene_value.gene.children.len != 1:
        not_allowed("read_tree expects 1 argument")

      let path_arg = eval_in_caller_context(vm, gene_value.gene.children[0], caller_frame)
      if path_arg.kind != VkString:
        not_allowed("read_tree expects a string path")

      let lazy_value = gene_value.gene.props.getOrDefault("lazy".to_key(), NIL)
      let options = build_tree_read_options(lazy_value)
      read_tree_root_path(path_arg.str, options)

# Initialize the serdes namespace
proc init_serdes*() =
  init_lazy_tree_value_class()
  tag_stdlib_serialization_origins()
  let serdes_ns = new_namespace("serdes")
  serdes_ns["serialize".to_key()] = NativeFn(vm_serialize).to_value()
  serdes_ns["deserialize".to_key()] = NativeFn(vm_deserialize).to_value()
  var write_tree_ref = new_ref(VkNativeMacro)
  write_tree_ref.native_macro = vm_write_tree_macro
  serdes_ns["write_tree".to_key()] = write_tree_ref.to_ref_value()
  var read_tree_ref = new_ref(VkNativeMacro)
  read_tree_ref.native_macro = vm_read_tree_macro
  serdes_ns["read_tree".to_key()] = read_tree_ref.to_ref_value()
  App.app.gene_ns.ref.ns["serdes".to_key()] = serdes_ns.to_value()
  # Retag gene after attaching gene/serdes so that the new namespace itself
  # also gets a canonical stdlib path.
  tag_namespace_serialization_origins(App.app.gene_ns.ref.ns, "", "gene")
