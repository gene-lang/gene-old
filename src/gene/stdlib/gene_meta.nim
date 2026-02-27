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
