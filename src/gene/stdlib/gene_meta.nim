import tables

import ../types
import ./classes

proc init_gene_and_meta_classes*(object_class: Class) =
  var r: ptr Reference
  let gene_class = new_class("Gene")
  gene_class.parent = object_class
  gene_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = gene_class
  App.app.gene_class = r.to_ref_value()
  App.app.gene_ns.ns["Gene".to_key()] = App.app.gene_class
  App.app.global_ns.ns["Gene".to_key()] = App.app.gene_class

  proc gene_type_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Gene.type requires self")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.type must be called on a gene")
    gene_val.gene.type

  gene_class.def_native_method("type", gene_type_method)

  proc gene_props_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Gene.props requires self")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.props must be called on a gene")
    let result_ref = new_map_value()
    for key, value in gene_val.gene.props:
      map_data(result_ref)[key] = value
    result_ref

  gene_class.def_native_method("props", gene_props_method)

  proc gene_children_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Gene.children requires self")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.children must be called on a gene")
    var result_ref = new_array_value()
    for child in gene_val.gene.children:
      array_data(result_ref).add(child)
    result_ref

  gene_class.def_native_method("children", gene_children_method)

  # Gene property (member) APIs
  proc gene_has_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Gene.has requires a key")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.has must be called on a gene")
    let key_val = get_positional_arg(args, 1, has_keyword_args)
    case key_val.kind
    of VkString, VkSymbol:
      return gene_val.gene.props.hasKey(key_val.str.to_key()).to_value()
    else:
      not_allowed("Gene.has key must be a string or symbol")

  gene_class.def_native_method("has", gene_has_method)

  proc gene_get_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Gene.get requires a key")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.get must be called on a gene")
    let key_val = get_positional_arg(args, 1, has_keyword_args)
    var key: Key
    case key_val.kind
    of VkString, VkSymbol:
      key = key_val.str.to_key()
    else:
      not_allowed("Gene.get key must be a string or symbol")
    if gene_val.gene.props.hasKey(key):
      return gene_val.gene.props[key]
    if pos_count >= 3:
      return get_positional_arg(args, 2, has_keyword_args)
    NIL

  gene_class.def_native_method("get", gene_get_method)

  proc gene_set_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Gene.set requires key and value")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.set must be called on a gene")
    let key_val = get_positional_arg(args, 1, has_keyword_args)
    var key: Key
    case key_val.kind
    of VkString, VkSymbol:
      key = key_val.str.to_key()
    else:
      not_allowed("Gene.set key must be a string or symbol")
    let value = get_positional_arg(args, 2, has_keyword_args)
    gene_val.gene.props[key] = value
    gene_val

  gene_class.def_native_method("set", gene_set_method)

  proc gene_del_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Gene.del requires a key")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.del must be called on a gene")
    var last_removed = NIL
    for i in 1..<pos_count:
      let key_val = get_positional_arg(args, i, has_keyword_args)
      var key: Key
      case key_val.kind
      of VkString, VkSymbol:
        key = key_val.str.to_key()
      else:
        not_allowed("Gene.del key must be a string or symbol")
      if gene_val.gene.props.hasKey(key):
        last_removed = gene_val.gene.props[key]
        gene_val.gene.props.del(key)
    last_removed

  gene_class.def_native_method("del", gene_del_method)

  # Gene child APIs
  proc gene_has_child_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Gene.has_child requires an index")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.has_child must be called on a gene")
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if idx_val.kind != VkInt:
      not_allowed("Gene.has_child index must be an integer")
    let idx = idx_val.int64.int
    (idx >= 0 and idx < gene_val.gene.children.len).to_value()

  gene_class.def_native_method("has_child", gene_has_child_method)

  proc gene_get_child_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Gene.get_child requires an index")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.get_child must be called on a gene")
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if idx_val.kind != VkInt:
      not_allowed("Gene.get_child index must be an integer")
    let idx = idx_val.int64.int
    if idx >= 0 and idx < gene_val.gene.children.len:
      return gene_val.gene.children[idx]
    if pos_count >= 3:
      return get_positional_arg(args, 2, has_keyword_args)
    NIL

  gene_class.def_native_method("get_child", gene_get_child_method)

  proc gene_set_child_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Gene.set_child requires index and value")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.set_child must be called on a gene")
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if idx_val.kind != VkInt:
      not_allowed("Gene.set_child index must be an integer")
    let idx = idx_val.int64.int
    if idx < 0 or idx >= gene_val.gene.children.len:
      not_allowed("Gene.set_child index out of bounds")
    let value = get_positional_arg(args, 2, has_keyword_args)
    gene_val.gene.children[idx] = value
    gene_val

  gene_class.def_native_method("set_child", gene_set_child_method)

  proc gene_add_child_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Gene.add_child requires a value")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.add_child must be called on a gene")
    let value = get_positional_arg(args, 1, has_keyword_args)
    gene_val.gene.children.add(value)
    gene_val

  gene_class.def_native_method("add_child", gene_add_child_method)

  proc gene_ins_child_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Gene.ins_child requires index and value")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.ins_child must be called on a gene")
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if idx_val.kind != VkInt:
      not_allowed("Gene.ins_child index must be an integer")
    let idx = idx_val.int64.int
    if idx < 0 or idx > gene_val.gene.children.len:
      not_allowed("Gene.ins_child index out of bounds")
    let value = get_positional_arg(args, 2, has_keyword_args)
    gene_val.gene.children.insert(value, idx)
    gene_val

  gene_class.def_native_method("ins_child", gene_ins_child_method)

  proc gene_del_child_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Gene.del_child requires an index")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.del_child must be called on a gene")
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if idx_val.kind != VkInt:
      not_allowed("Gene.del_child index must be an integer")
    let idx = idx_val.int64.int
    if idx < 0 or idx >= gene_val.gene.children.len:
      not_allowed("Gene.del_child index out of bounds")
    let removed = gene_val.gene.children[idx]
    gene_val.gene.children.delete(idx)
    removed

  gene_class.def_native_method("del_child", gene_del_child_method)

  proc gene_contains_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Gene.contains requires a value")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.contains must be called on a gene")
    let needle = get_positional_arg(args, 1, has_keyword_args)
    for child in gene_val.gene.children:
      if child == needle:
        return TRUE
    FALSE

  gene_class.def_native_method("contains", gene_contains_method)

  # genetype is alias for type
  gene_class.def_native_method("genetype", gene_type_method)

  proc gene_set_genetype_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Gene.set_genetype requires a type value")
    let gene_val = get_positional_arg(args, 0, has_keyword_args)
    if gene_val.kind != VkGene:
      not_allowed("Gene.set_genetype must be called on a gene")
    let new_type = get_positional_arg(args, 1, has_keyword_args)
    gene_val.gene.type = new_type
    gene_val

  gene_class.def_native_method("set_genetype", gene_set_genetype_method)

  let function_class = new_class("Function")
  function_class.parent = object_class

  proc function_intent_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                              arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Function.intent requires self")
    let fn_val = get_positional_arg(args, 0, has_keyword_args)
    if fn_val.kind != VkFunction:
      not_allowed("Function.intent must be called on a function")
    let fn_obj = fn_val.ref.fn
    if fn_obj == nil:
      return NIL
    fn_obj.intent.to_value()

  proc function_examples_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                                arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Function.examples requires self")
    let fn_val = get_positional_arg(args, 0, has_keyword_args)
    if fn_val.kind != VkFunction:
      not_allowed("Function.examples must be called on a function")
    let fn_obj = fn_val.ref.fn
    if fn_obj == nil:
      return new_array_value()

    let out_arr = new_array_value()
    for example in fn_obj.examples:
      let arg_arr = new_array_value()
      for arg_expr in example.args:
        array_data(arg_arr).add(arg_expr)
      array_data(out_arr).add(arg_arr)
      case example.expectation_kind
      of FekThrows:
        array_data(out_arr).add("throws".to_symbol_value())
        array_data(out_arr).add(example.expected)
      of FekAnyReturn:
        array_data(out_arr).add("->".to_symbol_value())
        array_data(out_arr).add("_".to_symbol_value())
      of FekReturn:
        array_data(out_arr).add("->".to_symbol_value())
        array_data(out_arr).add(example.expected)
    out_arr

  proc function_call_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                            arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 1:
      not_allowed("Function.call requires self")
    let fn_val = get_positional_arg(args, 0, has_keyword_args)
    if fn_val.kind notin {VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock}:
      not_allowed("Function.call must be called on a callable")
    var call_args = newSeq[Value]()
    for i in 1..<pos_count:
      call_args.add(get_positional_arg(args, i, has_keyword_args))
    {.cast(gcsafe).}:
      vm_exec_callable(vm, fn_val, call_args)

  function_class.def_native_method("call", function_call_method)
  function_class.def_native_method("intent", function_intent_method)
  function_class.def_native_method("examples", function_examples_method)

  let function_intent_fn = new_ref(VkNativeFn)
  function_intent_fn.native_fn = function_intent_method
  App.app.gene_ns.ns["function_intent".to_key()] = function_intent_fn.to_ref_value()
  App.app.global_ns.ns["function_intent".to_key()] = function_intent_fn.to_ref_value()

  let function_examples_fn = new_ref(VkNativeFn)
  function_examples_fn.native_fn = function_examples_method
  App.app.gene_ns.ns["function_examples".to_key()] = function_examples_fn.to_ref_value()
  App.app.global_ns.ns["function_examples".to_key()] = function_examples_fn.to_ref_value()

  r = new_ref(VkClass)
  r.class = function_class
  App.app.function_class = r.to_ref_value()
  App.app.gene_ns.ns["Function".to_key()] = App.app.function_class
  App.app.global_ns.ns["Function".to_key()] = App.app.function_class

  let char_class = new_class("Char")
  char_class.parent = object_class
  char_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = char_class
  App.app.char_class = r.to_ref_value()
  App.app.gene_ns.ns["Char".to_key()] = App.app.char_class
  App.app.global_ns.ns["Char".to_key()] = App.app.char_class

  let application_class = new_class("Application")
  application_class.parent = object_class
  r = new_ref(VkClass)
  r.class = application_class
  App.app.application_class = r.to_ref_value()
  App.app.gene_ns.ns["Application".to_key()] = App.app.application_class
  App.app.global_ns.ns["Application".to_key()] = App.app.application_class

  proc package_name_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                           arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Package.name requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkPackage or self_arg.ref.pkg == nil:
      not_allowed("Package.name must be called on a package")
    self_arg.ref.pkg.name.to_value()

  let package_class = new_class("Package")
  package_class.parent = object_class
  package_class.def_native_method("name", package_name_method)
  r = new_ref(VkClass)
  r.class = package_class
  App.app.package_class = r.to_ref_value()
  App.app.gene_ns.ns["Package".to_key()] = App.app.package_class
  App.app.global_ns.ns["Package".to_key()] = App.app.package_class

  let namespace_class = new_class("Namespace")
  namespace_class.parent = object_class
  r = new_ref(VkClass)
  r.class = namespace_class
  App.app.namespace_class = r.to_ref_value()
  App.app.gene_ns.ns["Namespace".to_key()] = App.app.namespace_class
  App.app.global_ns.ns["Namespace".to_key()] = App.app.namespace_class

  # Namespace member APIs
  proc ns_has_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Namespace.has requires a key")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.has must be called on a namespace")
    let key_val = get_positional_arg(args, 1, has_keyword_args)
    case key_val.kind
    of VkString, VkSymbol:
      return ns_val.ref.ns.members.hasKey(key_val.str.to_key()).to_value()
    else:
      not_allowed("Namespace.has key must be a string or symbol")

  namespace_class.def_native_method("has", ns_has_method)

  proc ns_get_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Namespace.get requires a key")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.get must be called on a namespace")
    let key_val = get_positional_arg(args, 1, has_keyword_args)
    var key: Key
    case key_val.kind
    of VkString, VkSymbol:
      key = key_val.str.to_key()
    else:
      not_allowed("Namespace.get key must be a string or symbol")
    if ns_val.ref.ns.members.hasKey(key):
      return ns_val.ref.ns.members[key]
    if pos_count >= 3:
      return get_positional_arg(args, 2, has_keyword_args)
    NIL

  namespace_class.def_native_method("get", ns_get_method)

  proc ns_set_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Namespace.set requires key and value")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.set must be called on a namespace")
    let key_val = get_positional_arg(args, 1, has_keyword_args)
    var key: Key
    case key_val.kind
    of VkString, VkSymbol:
      key = key_val.str.to_key()
    else:
      not_allowed("Namespace.set key must be a string or symbol")
    let value = get_positional_arg(args, 2, has_keyword_args)
    ns_val.ref.ns.members[key] = value
    ns_val

  namespace_class.def_native_method("set", ns_set_method)

  proc ns_del_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Namespace.del requires a key")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.del must be called on a namespace")
    var last_removed = NIL
    for i in 1..<pos_count:
      let key_val = get_positional_arg(args, i, has_keyword_args)
      var key: Key
      case key_val.kind
      of VkString, VkSymbol:
        key = key_val.str.to_key()
      else:
        not_allowed("Namespace.del key must be a string or symbol")
      if ns_val.ref.ns.members.hasKey(key):
        last_removed = ns_val.ref.ns.members[key]
        ns_val.ref.ns.members.del(key)
    last_removed

  namespace_class.def_native_method("del", ns_del_method)

  proc ns_empty_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.empty requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.empty must be called on a namespace")
    (ns_val.ref.ns.members.len == 0).to_value()

  namespace_class.def_native_method("empty", ns_empty_method)

  proc ns_clear_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.clear requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.clear must be called on a namespace")
    ns_val.ref.ns.members.clear()
    ns_val

  namespace_class.def_native_method("clear", ns_clear_method)

  proc ns_size_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.size requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.size must be called on a namespace")
    ns_val.ref.ns.members.len.to_value()

  namespace_class.def_native_method("size", ns_size_method)

  proc ns_keys_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.keys requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.keys must be called on a namespace")
    var result_ref = new_array_value()
    for key, _ in ns_val.ref.ns.members:
      let key_val = cast[Value](key)
      array_data(result_ref).add(key_val.str.to_value())
    result_ref

  namespace_class.def_native_method("keys", ns_keys_method)

  proc ns_values_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.values requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.values must be called on a namespace")
    var result_ref = new_array_value()
    for _, value in ns_val.ref.ns.members:
      array_data(result_ref).add(value)
    result_ref

  namespace_class.def_native_method("values", ns_values_method)

  proc ns_pairs_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.pairs requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.pairs must be called on a namespace")
    var result_ref = new_array_value()
    for key, value in ns_val.ref.ns.members:
      var pair = new_array_value()
      let key_val = cast[Value](key)
      array_data(pair).add(key_val.str.to_value())
      array_data(pair).add(value)
      array_data(result_ref).add(pair)
    result_ref

  namespace_class.def_native_method("pairs", ns_pairs_method)

  proc ns_each_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Namespace.each requires a function")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.each must be called on a namespace")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    case callback.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for key, value in ns_val.ref.ns.members:
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          discard vm_exec_callable(vm, callback, @[key_val.str.to_value(), value])
    else:
      not_allowed("each callback must be callable, got " & $callback.kind)
    ns_val

  namespace_class.def_native_method("each", ns_each_method)

  proc ns_map_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Namespace.map requires a function")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.map must be called on a namespace")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    var result_ref = new_map_value()
    case callback.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for key, value in ns_val.ref.ns.members:
        let key_val = cast[Value](key).str.to_value()
        var mapped: Value
        {.cast(gcsafe).}:
          mapped = vm_exec_callable(vm, callback, @[key_val, value])
        map_data(result_ref)[key] = mapped
    else:
      not_allowed("map callback must be callable, got " & $callback.kind)
    result_ref

  namespace_class.def_native_method("map", ns_map_method)

  proc ns_reduce_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Namespace.reduce requires an initial value and a reducer function")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.reduce must be called on a namespace")
    var accumulator = get_positional_arg(args, 1, has_keyword_args)
    let reducer = get_positional_arg(args, 2, has_keyword_args)
    case reducer.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for key, value in ns_val.ref.ns.members:
        let key_val = cast[Value](key).str.to_value()
        {.cast(gcsafe).}:
          accumulator = vm_exec_callable(vm, reducer, @[accumulator, key_val, value])
    else:
      not_allowed("reduce reducer must be callable, got " & $reducer.kind)
    accumulator

  namespace_class.def_native_method("reduce", ns_reduce_method)

  proc ns_on_member_missing_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("on_member_missing requires a handler function")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("on_member_missing must be called on a namespace")
    let handler = get_positional_arg(args, 1, has_keyword_args)
    case handler.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      ns_val.ref.ns.on_member_missing.add(handler)
    else:
      not_allowed("on_member_missing handler must be callable, got " & $handler.kind)
    ns_val

  namespace_class.def_native_method("on_member_missing", ns_on_member_missing_method)

  proc ns_name_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Namespace.name requires self")
    let ns_val = get_positional_arg(args, 0, has_keyword_args)
    if ns_val.kind != VkNamespace:
      not_allowed("Namespace.name must be called on a namespace")
    ns_val.ref.ns.name.to_value()

  namespace_class.def_native_method("name", ns_name_method)
