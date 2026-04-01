## VM helper procs: expected_type_id_for, find_named_type_descriptor,
## ensure_class_runtime_type, native_args_supported, skip_wildcard_import_key,
## resolve_local_or_namespace, import_items, get_value_class template,
## enter_function, exit_function.
## Included from vm.nim — shares its scope.

proc expected_type_id_for(tracker: ScopeTracker, index: int): TypeId {.inline.} =
  if tracker == nil:
    return NO_TYPE_ID
  if index < 0 or index >= tracker.type_expectation_ids.len:
    return NO_TYPE_ID
  tracker.type_expectation_ids[index]

proc runtime_type_error_location(self: ptr VirtualMachine): string {.inline.} =
  if self == nil or self.cu == nil:
    return ""
  var trace: SourceTrace = nil
  if self.pc >= 0 and self.pc < self.cu.instruction_traces.len:
    trace = self.cu.instruction_traces[self.pc]
  if trace == nil and self.cu.trace_root != nil:
    trace = self.cu.trace_root
  trace_location(trace)

proc validate_local_type_constraint(self: ptr VirtualMachine, tracker: ScopeTracker, index: int,
                                    value: Value, context = "variable") {.inline.} =
  if self == nil or tracker == nil or not self.type_check:
    return
  if value == NIL or self.cu == nil or self.cu.type_descriptors.len == 0:
    return
  let expected_id = expected_type_id_for(tracker, index)
  if expected_id == NO_TYPE_ID:
    return
  validate_type(value, expected_id, self.cu.type_descriptors, context, self.runtime_type_error_location())

proc validate_return_type_constraint(self: ptr VirtualMachine, value: var Value) {.inline.} =
  if self == nil or not self.type_check:
    return
  if self.frame == nil or self.frame.target.kind != VkFunction:
    return
  let f = self.frame.target.ref.fn
  if f == nil or f.matcher == nil:
    return
  if value == NIL or f.matcher.return_type_id == NO_TYPE_ID or f.matcher.type_descriptors.len == 0:
    return
  let warning = validate_or_coerce_type(value, f.matcher.return_type_id, f.matcher.type_descriptors,
    "return value of " & f.name, self.runtime_type_error_location())
  emit_type_warning(warning)

proc find_named_type_descriptor(cu: CompilationUnit, name: string): tuple[type_id: TypeId, desc: TypeDesc, found: bool] =
  let builtin_id = lookup_builtin_type(name)
  if builtin_id != NO_TYPE_ID:
    return (builtin_id, builtin_type_descs()[builtin_id.int], true)
  if cu == nil:
    return (NO_TYPE_ID, TypeDesc(module_path: "", kind: TdkNamed, name: name), false)
  for i, desc in cu.type_descriptors:
    if desc.kind == TdkNamed and desc.name == name:
      return (i.int32, desc, true)
  (NO_TYPE_ID, TypeDesc(module_path: cu.module_path, kind: TdkNamed, name: name), false)

proc ensure_named_type_descriptor(cu: CompilationUnit, name: string): tuple[type_id: TypeId, desc: TypeDesc, found: bool] =
  let lookup = find_named_type_descriptor(cu, name)
  if lookup.found:
    return lookup
  if cu == nil:
    return lookup

  var desc_index = initTable[string, TypeId]()
  ensure_type_desc_index(cu.type_descriptors, desc_index)
  let type_id = intern_type_desc(cu.type_descriptors,
    TypeDesc(module_path: cu.module_path, kind: TdkNamed, name: name), desc_index)
  cu.type_registry = populate_registry(cu.type_descriptors, cu.module_path)
  (type_id, cu.type_descriptors[type_id.int], true)

proc ensure_class_runtime_type(self: ptr VirtualMachine, class: Class): RtTypeObj =
  if class == nil:
    return nil
  if class.runtime_type != nil:
    return class.runtime_type
  let lookup = ensure_named_type_descriptor(self.cu, class.name)
  class.runtime_type = new_runtime_type_object(lookup.type_id, lookup.desc)
  class.runtime_type

proc current_runtime_type_descs(self: ptr VirtualMachine): seq[TypeDesc] =
  if self != nil and self.cu != nil and self.cu.type_descriptors.len > 0:
    return self.cu.type_descriptors
  builtin_type_descs()

proc normalize_runtime_type_input(value: Value): Value =
  case value.kind
  of VkClass:
    if value.ref != nil and value.ref.class != nil and value.ref.class.name.len > 0:
      return value.ref.class.name.to_symbol_value()
    return "Any".to_symbol_value()
  of VkComplexSymbol:
    if value.ref != nil and value.ref.csymbol.len > 0:
      return value.ref.csymbol.join("/").to_symbol_value()
    return "Any".to_symbol_value()
  of VkString:
    if value.str.len == 0:
      return "Any".to_symbol_value()
    return value.str.to_symbol_value()
  else:
    return value

proc resolve_runtime_type_arg(self: ptr VirtualMachine, value: Value): tuple[type_id: TypeId, type_descs: seq[TypeDesc], found: bool] =
  if is_runtime_type_value(value):
    let payload = runtime_type_payload(value)
    return (payload.runtime_type.type_id, payload.type_descs, true)

  case value.kind
  of VkClass:
    let rt = self.ensure_class_runtime_type(value.ref.class)
    if rt == nil:
      return (NO_TYPE_ID, @[], false)
    return (rt.type_id, self.current_runtime_type_descs(), true)
  of VkSymbol, VkString, VkComplexSymbol, VkGene:
    var descs = self.current_runtime_type_descs()
    let aliases = if self != nil and self.cu != nil: self.cu.type_aliases else: initTable[string, TypeId]()
    let module_path = if self != nil and self.cu != nil: self.cu.module_path else: ""
    let type_id = resolve_type_value_to_id(normalize_runtime_type_input(value), descs, aliases, module_path)
    if self != nil and self.cu != nil:
      self.cu.type_descriptors = descs
      self.cu.type_registry = populate_registry(self.cu.type_descriptors, self.cu.module_path)
    return (type_id, descs, true)
  else:
    (NO_TYPE_ID, @[], false)

proc native_args_supported(f: Function, args: seq[Value]): bool =
  const nativeArgLimit =
    when defined(arm64) or defined(aarch64):
      7
    elif defined(amd64):
      5
    else:
      0
  if nativeArgLimit == 0:
    return false
  if f.matcher.is_nil or not f.matcher.has_type_annotations:
    return false
  if f.matcher.children.len != args.len:
    return false
  if args.len > nativeArgLimit:
    return false
  for i, param in f.matcher.children:
    let tid = param.type_id
    if tid == BUILTIN_TYPE_INT_ID:
      if args[i].kind != VkInt:
        return false
    elif tid == BUILTIN_TYPE_FLOAT_ID:
      if args[i].kind != VkFloat:
        return false
    elif tid == BUILTIN_TYPE_STRING_ID:
      if args[i].kind != VkString:
        return false
    else:
      return false
  true

proc effective_native_tier(self: ptr VirtualMachine): NativeCompileTier {.inline.} =
  if self == nil:
    return NctNever
  if self.native_tier == NctNever and self.native_code:
    return NctGuarded
  self.native_tier

proc native_has_fully_typed_boundary(f: Function): bool {.inline.} =
  if f == nil or f.matcher == nil:
    return false
  if f.matcher.return_type_id == NO_TYPE_ID:
    return false
  f.matcher.return_type_id == BUILTIN_TYPE_INT_ID or
    f.matcher.return_type_id == BUILTIN_TYPE_FLOAT_ID or
    f.matcher.return_type_id == BUILTIN_TYPE_STRING_ID

proc native_call_supported(self: ptr VirtualMachine, f: Function, args: seq[Value]): bool =
  let tier = self.effective_native_tier()
  if tier == NctNever:
    return false
  if not native_args_supported(f, args):
    return false
  if tier == NctFullyTyped and not native_has_fully_typed_boundary(f):
    return false
  true

## try_native_call, native_trampoline moved to vm/native.nim
## (included later, after forward declarations)
proc skip_wildcard_import_key(key: Key): bool {.inline.} =
  key == "__module_name__".to_key() or
  key == "__is_main__".to_key() or
  key == "__init__".to_key() or
  key == "__init_ran__".to_key() or
  key == "__compiled__".to_key() or
  key == "__exports__".to_key() or
  key == "gene".to_key() or
  key == "genex".to_key()

proc resolve_namespace_value(ns: Namespace, key: Key): tuple[found: bool, value: Value, owner: Namespace] =
  if ns != nil and ns.has_key(key):
    let located = ns.locate(key)
    return (true, located[0], located[1])
  (false, NIL, nil)

proc resolve_local_or_namespace(self: ptr VirtualMachine, name: string): tuple[found: bool, value: Value] =
  let key = name.to_key()
  if self.frame != nil and self.frame.scope != nil and self.frame.scope.tracker != nil:
    let found = self.frame.scope.tracker.locate(key)
    if found.local_index >= 0:
      var scope = self.frame.scope
      var parent_index = found.parent_index
      while parent_index > 0 and scope != nil:
        parent_index.dec()
        scope = scope.parent
      if scope != nil and found.local_index < scope.members.len:
        return (true, scope.members[found.local_index])
  let ns_resolved =
    if self.frame != nil: resolve_namespace_value(self.frame.ns, key)
    else: (false, NIL, nil)
  if ns_resolved.found:
    return (true, ns_resolved.value)
  return (false, NIL)

proc import_items(self: ptr VirtualMachine, source_ns: Namespace, items: seq[ImportItem]) =
  if source_ns == nil or self.frame == nil or self.frame.ns == nil:
    return

  let export_enforced = has_exports(source_ns)

  for item in items:
    if item.name == "*":
      for key, value in source_ns.members:
        if value != NIL and not skip_wildcard_import_key(key):
          if export_enforced:
            let symbol_name = get_symbol(symbol_index(key))
            if not is_exported(source_ns, symbol_name):
              continue
          self.frame.ns.members[key] = value
    else:
      if export_enforced and not is_exported(source_ns, item.name):
        not_allowed("[GENE.IMPORT.EXPORT_MISSING] Cannot import '" & item.name &
          "' from module with explicit exports")
      let value = resolve_import_value(source_ns, item.name)
      let import_name = if item.alias != "":
        item.alias
      else:
        let parts = item.name.split("/")
        parts[^1]
      self.frame.ns.members[import_name.to_key()] = value

# Resolve an application class value safely.
# Some runtime paths may observe NIL/uninitialized class slots; avoid
# variant-field defects by checking the tag before dereferencing.
template safe_class_value(val: Value): Class =
  if val.kind == VkClass:
    types.ref(val).class
  else:
    nil

# Template to get the class of a value for unified method calls
template get_value_class(val: Value): Class =
  case val.kind:
  of VkCustom:
    types.ref(val).custom_class
  of VkInstance:
    instance_class(val)
  of VkNil:
    safe_class_value(App.app.nil_class)
  of VkVoid:
    safe_class_value(App.app.void_class)
  of VkBool:
    safe_class_value(App.app.bool_class)
  of VkInt:
    safe_class_value(App.app.int_class)
  of VkFloat:
    safe_class_value(App.app.float_class)
  of VkChar:
    safe_class_value(App.app.char_class)
  of VkString:
    safe_class_value(App.app.string_class)
  of VkSymbol:
    safe_class_value(App.app.symbol_class)
  of VkComplexSymbol:
    safe_class_value(App.app.complex_symbol_class)
  of VkArray:
    safe_class_value(App.app.array_class)
  of VkMap:
    safe_class_value(App.app.map_class)
  of VkHashMap:
    safe_class_value(App.app.hash_map_class)
  of VkRange:
    safe_class_value(App.app.range_class)
  of VkGene:
    safe_class_value(App.app.gene_class)
  of VkDate:
    safe_class_value(App.app.date_class)
  of VkDateTime:
    safe_class_value(App.app.datetime_class)
  of VkSet:
    safe_class_value(App.app.hash_set_class)
  of VkSelector:
    safe_class_value(App.app.selector_class)
  of VkRegex:
    safe_class_value(App.app.regex_class)
  of VkFuture:
    safe_class_value(App.app.future_class)
  of VkGenerator:
    safe_class_value(App.app.generator_class)
  of VkPackage:
    safe_class_value(App.app.package_class)
  of VkApplication:
    safe_class_value(App.app.application_class)
  of VkThread:
    safe_class_value(THREAD_CLASS_VALUE)
  of VkThreadMessage:
    safe_class_value(THREAD_MESSAGE_CLASS_VALUE)
  of VkClass:
    safe_class_value(App.app.class_class)
  of VkInterface:
    safe_class_value(App.app.interface_class)
  of VkAdapter:
    safe_class_value(App.app.adapter_class)
  of VkAdapterInternal:
    safe_class_value(App.app.map_class)
  of VkAspect:
    safe_class_value(App.app.aspect_class)
  of VkNamespace:
    safe_class_value(App.app.namespace_class)
  of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
    safe_class_value(App.app.function_class)
  else:
    safe_class_value(App.app.object_class)

proc enter_function(self: ptr VirtualMachine, name: string) {.inline.} =
  if self.profiling:
    let start_time = cpuTime()
    self.profile_stack.add((name, start_time))
    
proc exit_function(self: ptr VirtualMachine) {.inline.} =
  if self.profiling and self.profile_stack.len > 0:
    let (fn_name, start_time) = self.profile_stack[^1]
    self.profile_stack.del(self.profile_stack.len - 1)
    
    let end_time = cpuTime()
    let elapsed = end_time - start_time
    
    # Update or create profile entry
    if fn_name notin self.profile_data:
      self.profile_data[fn_name] = FunctionProfile(
        name: fn_name,
        call_count: 0,
        total_time: 0.0,
        self_time: 0.0,
        min_time: elapsed,
        max_time: elapsed
      )
    
    var profile = self.profile_data[fn_name]
    profile.call_count.inc()
    profile.total_time += elapsed
    
    # Update min/max
    if elapsed < profile.min_time:
      profile.min_time = elapsed
    if elapsed > profile.max_time:
      profile.max_time = elapsed
    
    # Calculate self time (subtract child call times)
    for i in countdown(self.profile_stack.len - 1, 0):
      if self.profile_stack[i].name == fn_name:
        break
      # This is a simplification - proper self time calculation is more complex
    profile.self_time = profile.total_time  # For now, just use total

    self.profile_data[fn_name] = profile
