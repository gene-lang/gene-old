import strutils, tables

import ../types
from ../types/runtime_types import coerce_value_to_type, emit_type_warning, runtime_type_name

proc display_value*(val: Value; top_level: bool): string {.gcsafe.} =
  case val.kind
  of VkNil:
    if top_level:
      ""
    else:
      "nil"
  of VkString:
    if top_level:
      val.str
    else:
      "\"" & val.str & "\""
  of VkSymbol:
    val.str
  of VkBool:
    if val == TRUE: "true" else: "false"
  of VkInt:
    $(to_int(val))
  of VkFloat:
    $(cast[float64](val))
  of VkArray:
    var parts: seq[string] = @[]
    for item in array_data(val):
      parts.add(display_value(item, false))
    "[" & parts.join(" ") & "]"
  of VkMap:
    var parts: seq[string] = @[]
    for k, v in map_data(val):
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      let key_name = get_symbol_gcsafe(symbol_index.int)
      parts.add("^" & key_name & " " & display_value(v, false))
    "{" & parts.join(" ") & "}"
  of VkGene:
    var segments: seq[string] = @[]
    if not val.gene.type.is_nil():
      segments.add(display_value(val.gene.type, false))
    for k, v in val.gene.props:
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      let key_name = get_symbol_gcsafe(symbol_index.int)
      segments.add("^" & key_name & " " & display_value(v, false))
    for child in val.gene.children:
      segments.add(display_value(child, false))
    "(" & segments.join(" ") & ")"
  else:
    $val

proc value_class_value*(val: Value): Value =
  case val.kind
  of VkNil:
    App.app.nil_class
  of VkBool:
    App.app.bool_class
  of VkInt:
    App.app.int_class
  of VkFloat:
    App.app.float_class
  of VkChar:
    App.app.char_class
  of VkString:
    App.app.string_class
  of VkSymbol:
    App.app.symbol_class
  of VkComplexSymbol:
    App.app.complex_symbol_class
  of VkArray:
    App.app.array_class
  of VkMap:
    App.app.map_class
  of VkGene:
    App.app.gene_class
  of VkRegex:
    App.app.regex_class
  of VkDate:
    App.app.date_class
  of VkDateTime:
    App.app.datetime_class
  of VkSet:
    if App.app.set_class.kind == VkClass:
      App.app.set_class
    else:
      App.app.object_class
  of VkFuture:
    if App.app.future_class.kind == VkClass:
      App.app.future_class
    else:
      App.app.object_class
  of VkGenerator:
    if App.app.generator_class.kind == VkClass:
      App.app.generator_class
    else:
      App.app.object_class
  of VkNamespace:
    App.app.namespace_class
  of VkClass:
    App.app.class_class
  of VkInstance:
    let class_ref = new_ref(VkClass)
    class_ref.class = val.instance_class
    return class_ref.to_ref_value()
  of VkCustom:
    if val.ref.custom_class != nil:
      let class_ref = new_ref(VkClass)
      class_ref.class = val.ref.custom_class
      return class_ref.to_ref_value()
    else:
      App.app.object_class
  of VkSelector:
    App.app.selector_class
  else:
    App.app.object_class

proc object_class_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                         arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    return App.app.object_class
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  result = value_class_value(self_arg)

proc object_to_s_method*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                         arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    return "".to_value()
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  display_value(self_arg, true).to_value()

proc object_is_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                      arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional < 2:
    not_allowed("Object.is expects a class as the second argument")
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  let target_arg = get_positional_arg(args, 1, has_keyword_args)

  var target_class: Class
  case target_arg.kind
  of VkClass:
    target_class = target_arg.ref.class
  of VkInstance:
    target_class = target_arg.instance_class
  of VkCustom:
    target_class = target_arg.ref.custom_class
  else:
    not_allowed("Object.is expects a class or instance as the second argument")

  if target_class.is_nil:
    return FALSE

  let actual_class_value = value_class_value(self_arg)
  if actual_class_value.kind != VkClass:
    return FALSE

  var current = actual_class_value.ref.class
  while current != nil:
    if current == target_class:
      return TRUE
    current = current.parent
  return FALSE

proc object_to_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                      arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional < 2:
    not_allowed("Object.to expects a target type argument")

  let value_arg = get_positional_arg(args, 0, has_keyword_args)
  let target_arg = get_positional_arg(args, 1, has_keyword_args)

  var target_type = ""
  case target_arg.kind
  of VkClass:
    if target_arg.ref != nil and target_arg.ref.class != nil:
      target_type = target_arg.ref.class.name
  of VkSymbol, VkString:
    target_type = target_arg.str
  else:
    discard

  if target_type.len == 0:
    not_allowed("Object.to expects a class or type name")

  var converted = value_arg
  var warning = ""
  var converted_ok = false
  {.cast(gcsafe).}:
    let tid = lookup_builtin_type(target_type)
    if tid != NO_TYPE_ID:
      let descs = builtin_type_descs()
      converted_ok = coerce_value_to_type(value_arg, tid, descs, "value", converted, warning)
    else:
      let descs = @[TypeDesc(kind: TdkNamed, name: target_type)]
      converted_ok = coerce_value_to_type(value_arg, 0.TypeId, descs, "value", converted, warning)
  if converted_ok:
    {.cast(gcsafe).}:
      emit_type_warning(warning)
    return converted

  var actual_type = ""
  {.cast(gcsafe).}:
    actual_type = runtime_type_name(value_arg)
  raise new_exception(types.Exception,
    "Type error: cannot convert " & actual_type & " to " & target_type)

proc int_to_i_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                     arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    not_allowed("Int.to_i requires self")
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  if self_arg.kind != VkInt:
    not_allowed("to_i must be called on an int")
  self_arg

proc int_to_f_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                     arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    not_allowed("Int.to_f requires self")
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  if self_arg.kind != VkInt:
    not_allowed("to_f must be called on an int")
  system.float64(self_arg.int64).to_value()

proc float_to_i_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                       arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    not_allowed("Float.to_i requires self")
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  if self_arg.kind != VkFloat:
    not_allowed("to_i must be called on a float")
  system.int64(self_arg.float).to_value()

proc float_to_f_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                       arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    not_allowed("Float.to_f requires self")
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  if self_arg.kind != VkFloat:
    not_allowed("to_f must be called on a float")
  self_arg

proc init_basic_classes*(): Class =
  var r: ptr Reference

  let object_class = new_class("Object")
  r = new_ref(VkClass)
  r.class = object_class
  App.app.object_class = r.to_ref_value()

  object_class.def_native_method("class", object_class_method)
  object_class.def_native_method("to_s", object_to_s_method)
  object_class.def_native_method("is", object_is_method)
  object_class.def_native_method("to", object_to_method)
  App.app.gene_ns.ns["Object".to_key()] = App.app.object_class
  App.app.global_ns.ns["Object".to_key()] = App.app.object_class

  let nil_class = new_class("Nil")
  nil_class.parent = object_class
  nil_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = nil_class
  App.app.nil_class = r.to_ref_value()
  App.app.gene_ns.ns["Nil".to_key()] = App.app.nil_class
  App.app.global_ns.ns["Nil".to_key()] = App.app.nil_class

  let bool_class = new_class("Bool")
  bool_class.parent = object_class
  bool_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = bool_class
  App.app.bool_class = r.to_ref_value()
  App.app.gene_ns.ns["Bool".to_key()] = App.app.bool_class
  App.app.global_ns.ns["Bool".to_key()] = App.app.bool_class

  let int_class = new_class("Int")
  int_class.parent = object_class
  r = new_ref(VkClass)
  r.class = int_class
  App.app.int_class = r.to_ref_value()
  App.app.gene_ns.ns["Int".to_key()] = App.app.int_class
  App.app.global_ns.ns["Int".to_key()] = App.app.int_class
  int_class.def_native_method("to_s", object_to_s_method, @[], App.app.string_class)
  int_class.def_native_method("to_i", int_to_i_method, @[], App.app.int_class)

  let float_class = new_class("Float")
  float_class.parent = object_class
  r = new_ref(VkClass)
  r.class = float_class
  App.app.float_class = r.to_ref_value()
  App.app.gene_ns.ns["Float".to_key()] = App.app.float_class
  App.app.global_ns.ns["Float".to_key()] = App.app.float_class
  float_class.def_native_method("to_s", object_to_s_method, @[], App.app.string_class)
  float_class.def_native_method("to_i", float_to_i_method, @[], App.app.int_class)
  float_class.def_native_method("to_f", float_to_f_method, @[], App.app.float_class)
  int_class.def_native_method("to_f", int_to_f_method, @[], App.app.float_class)

  object_class

proc init_symbol_classes*(object_class: Class) =
  var r: ptr Reference
  let symbol_class = new_class("Symbol")
  symbol_class.parent = object_class
  symbol_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = symbol_class
  App.app.symbol_class = r.to_ref_value()
  App.app.gene_ns.ns["Symbol".to_key()] = App.app.symbol_class
  App.app.global_ns.ns["Symbol".to_key()] = App.app.symbol_class

  let complex_symbol_class = new_class("ComplexSymbol")
  complex_symbol_class.parent = object_class
  complex_symbol_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = complex_symbol_class
  App.app.complex_symbol_class = r.to_ref_value()
  App.app.gene_ns.ns["ComplexSymbol".to_key()] = App.app.complex_symbol_class
  App.app.global_ns.ns["ComplexSymbol".to_key()] = App.app.complex_symbol_class

proc to_ctor(node: Value): Function =
  let name = "ctor"

  let matcher = new_arg_matcher()
  matcher.parse(node.gene.children[0])
  matcher.check_hint()

  var body: seq[Value] = @[]
  for i in 1..<node.gene.children.len:
    body.add node.gene.children[i]

  result = new_fn(name, matcher, body)

proc class_ctor*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                 arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    not_allowed("class_ctor requires arguments")

  let args_gene = create_gene_args(args, arg_count, has_keyword_args)
  let fn = to_ctor(args_gene)
  fn.ns = vm.frame.ns
  let r = new_ref(VkFunction)
  r.fn = fn
  let x = args_gene.gene.type.ref.bound_method.self
  if x.kind == VkClass:
    x.ref.class.constructor = r.to_ref_value()
  else:
    not_allowed("Constructor can only be defined on classes")

proc class_fn*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
               arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    not_allowed("class_fn requires arguments")

  let args_gene = create_gene_args(args, arg_count, has_keyword_args)
  let x = args_gene.gene.type.ref.bound_method.self
  let fn =
    if vm != nil and vm.cu != nil:
      if vm.cu.type_registry == nil:
        vm.cu.type_registry = populate_registry(vm.cu.type_descriptors, vm.cu.module_path)
      to_function(args_gene, vm.cu.type_descriptors, vm.cu.type_aliases,
        vm.cu.module_path, vm.cu.type_registry)
    else:
      to_function(args_gene)

  let r = new_ref(VkFunction)
  r.fn = fn
  let m = Method(
    name: fn.name,
    callable: r.to_ref_value(),
    native_param_types: @[],
    native_return_type: NIL,
  )
  case x.kind
  of VkClass:
    let class = x.ref.class
    m.class = class
    fn.ns = class.ns
    class.methods[m.name.to_key()] = m
  else:
    not_allowed()

proc init_class_class*(object_class: Class) =
  var r: ptr Reference
  let class = new_class("Class")
  class.parent = object_class
  class.def_native_macro_method("ctor", class_ctor)
  class.def_native_macro_method("fn", class_fn)
  class.def_native_method "parent", proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) == 0:
      return NIL
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkClass:
      not_allowed("Class.parent must be called on a class")
    let parent_class = self_arg.ref.class.parent
    if parent_class != nil:
      let parent_ref = new_ref(VkClass)
      parent_ref.class = parent_class
      parent_ref.to_ref_value()
    else:
      NIL
  class.def_native_method "name", proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) == 0:
      return "".to_value()
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkClass:
      not_allowed("Class.name must be called on a class")
    self_arg.ref.class.name.to_value()
  class.def_native_method "method_intent", proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Class.method_intent requires class and method name")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkClass:
      not_allowed("Class.method_intent must be called on a class")
    let method_name_val = get_positional_arg(args, 1, has_keyword_args)
    if method_name_val.kind notin {VkSymbol, VkString}:
      not_allowed("Class.method_intent requires method name symbol/string")
    let method_obj = self_arg.ref.class.get_method(method_name_val.str.to_key())
    if method_obj == nil or method_obj.callable.kind != VkFunction or method_obj.callable.ref.fn == nil:
      return NIL
    method_obj.callable.ref.fn.intent.to_value()

  r = new_ref(VkClass)
  r.class = class
  App.app.class_class = r.to_ref_value()
  App.app.gene_ns.ns["Class".to_key()] = App.app.class_class
  App.app.global_ns.ns["Class".to_key()] = App.app.class_class
