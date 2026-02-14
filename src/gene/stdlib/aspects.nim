import tables

import ../types

proc normalize_advice_args(args_val: Value): Value =
  var normalized = new_array_value()
  case args_val.kind
  of VkArray:
    let src = array_data(args_val)
    if src.len == 0:
      array_data(normalized).add("self".to_symbol_value())
    elif src[0].kind == VkSymbol and src[0].str == "self":
      for arg in src:
        array_data(normalized).add(arg)
    else:
      array_data(normalized).add("self".to_symbol_value())
      for arg in src:
        array_data(normalized).add(arg)
  of VkSymbol:
    if args_val.str == "_" or args_val.str == "self":
      array_data(normalized).add("self".to_symbol_value())
    else:
      array_data(normalized).add("self".to_symbol_value())
      array_data(normalized).add(args_val)
  else:
    not_allowed("advice arguments must be an array or symbol")
  normalized

proc advice_user_arg_count(args_val: Value): int =
  case args_val.kind
  of VkArray:
    return array_data(args_val).len
  of VkSymbol:
    if args_val.str == "_" or args_val.str == "self":
      return 0
    return 1
  else:
    not_allowed("advice arguments must be an array or symbol")
    return 0

proc resolve_advice_callable(callable_val: Value, caller_frame: Frame): Value =
  case callable_val.kind
  of VkFunction, VkNativeFn:
    return callable_val
  of VkSymbol:
    let key = callable_val.str.to_key()
    var resolved = if caller_frame.ns != nil: caller_frame.ns[key] else: NIL
    if resolved == NIL:
      resolved = App.app.global_ns.ref.ns[key]
    if resolved == NIL:
      resolved = App.app.gene_ns.ref.ns[key]
    if resolved == NIL:
      resolved = App.app.genex_ns.ref.ns[key]
    if resolved == NIL:
      not_allowed("advice callable not found: " & callable_val.str)
    if resolved.kind notin {VkFunction, VkNativeFn}:
      not_allowed("advice callable must be a function or native function")
    return resolved
  else:
    not_allowed("advice callable must be a symbol")

proc aspect_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let gene = gene_value.gene
    if gene.children.len < 2:
      not_allowed("aspect requires a name and method parameters")

    let name_val = gene.children[0]
    if name_val.kind != VkSymbol:
      not_allowed("aspect name must be a symbol")
    let name = name_val.str

    let params_val = gene.children[1]
    if params_val.kind != VkArray:
      not_allowed("aspect parameter list must be an array")

    var param_names: seq[string] = @[]
    for p in array_data(params_val):
      if p.kind == VkSymbol:
        param_names.add(p.str)
      else:
        not_allowed("aspect parameter must be a symbol")

    let aspect = Aspect(
      name: name,
      param_names: param_names,
      before_advices: initTable[string, seq[Value]](),
      invariant_advices: initTable[string, seq[Value]](),
      after_advices: initTable[string, seq[AopAfterAdvice]](),
      around_advices: initTable[string, Value](),
      before_filter_advices: initTable[string, seq[Value]](),
      enabled: true
    )

    for i in 2..<gene.children.len:
      let advice_def = gene.children[i]
      if advice_def.kind != VkGene:
        not_allowed("advice definition must be a gene expression")

      let advice_gene = advice_def.gene
      if advice_gene.children.len < 2:
        not_allowed("advice requires type and target")

      let advice_type = advice_gene.type
      if advice_type.kind != VkSymbol:
        not_allowed("advice type must be a symbol")
      let advice_type_str = advice_type.str

      var replace_result = false
      let replace_key = "replace_result".to_key()
      if advice_gene.props.has_key(replace_key):
        let replace_val = advice_gene.props[replace_key]
        replace_result = (replace_val == NIL or replace_val == PLACEHOLDER) or replace_val.to_bool()
        if replace_result and advice_type_str != "after":
          not_allowed("replace_result is only allowed for after advices")

      let target = advice_gene.children[0]
      if target.kind != VkSymbol:
        not_allowed("advice target must be a method parameter symbol")
      let target_name = target.str

      if not (target_name in param_names):
        not_allowed("advice target '" & target_name & "' is not a defined method parameter")

      var advice_val: Value
      var user_arg_count = -1
      if advice_gene.children.len == 2:
        advice_val = resolve_advice_callable(advice_gene.children[1], caller_frame)
      else:
        user_arg_count = advice_user_arg_count(advice_gene.children[1])
        let matcher = new_arg_matcher()
        let matcher_args = normalize_advice_args(advice_gene.children[1])
        matcher.parse(matcher_args)
        matcher.check_hint()

        var body: seq[Value] = @[]
        for j in 2..<advice_gene.children.len:
          body.add(advice_gene.children[j])

        let advice_fn = new_fn(advice_type_str & "_advice", matcher, body)
        advice_fn.ns = caller_frame.ns
        advice_fn.parent_scope = caller_frame.scope

        var scope_tracker = new_scope_tracker()
        for m in matcher.children:
          if m.kind == MatchData and m.name_key != Key(0):
            scope_tracker.add(m.name_key)
        advice_fn.scope_tracker = scope_tracker

        let advice_fn_ref = new_ref(VkFunction)
        advice_fn_ref.fn = advice_fn
        advice_val = advice_fn_ref.to_ref_value()

      case advice_type_str:
      of "before":
        if not aspect.before_advices.hasKey(target_name):
          aspect.before_advices[target_name] = @[]
        aspect.before_advices[target_name].add(advice_val)
      of "after":
        if not aspect.after_advices.hasKey(target_name):
          aspect.after_advices[target_name] = @[]
        aspect.after_advices[target_name].add(AopAfterAdvice(
          callable: advice_val,
          replace_result: replace_result,
          user_arg_count: user_arg_count
        ))
      of "invariant":
        if not aspect.invariant_advices.hasKey(target_name):
          aspect.invariant_advices[target_name] = @[]
        aspect.invariant_advices[target_name].add(advice_val)
      of "around":
        if aspect.around_advices.hasKey(target_name):
          not_allowed("around advice already defined for '" & target_name & "'")
        aspect.around_advices[target_name] = advice_val
      of "before_filter":
        if not aspect.before_filter_advices.hasKey(target_name):
          aspect.before_filter_advices[target_name] = @[]
        aspect.before_filter_advices[target_name].add(advice_val)
      else:
        not_allowed("unknown advice type: " & advice_type_str)

    let aspect_ref = new_ref(VkAspect)
    aspect_ref.aspect = aspect
    let aspect_val = aspect_ref.to_ref_value()

    caller_frame.ns[name.to_key()] = aspect_val

    return aspect_val

proc create_interception_value(original: Value, aspect_value: Value, param_name: string): Value =
  let interception = Interception(
    original: original,
    aspect: aspect_value,
    param_name: param_name,
    active: true
  )
  let interception_ref = new_ref(VkInterception)
  interception_ref.interception = interception
  interception_ref.to_ref_value()

proc aspect_apply(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 2:
    not_allowed("aspect.apply requires self and class arguments")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkAspect:
    not_allowed("apply must be called on an aspect")

  let aspect = self.ref.aspect

  let class_arg = get_positional_arg(args, 1, has_keyword_args)
  if class_arg.kind != VkClass:
    not_allowed("aspect.apply requires a class argument")

  let class = class_arg.ref.class

  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional - 2 != aspect.param_names.len:
    not_allowed("aspect.apply requires " & $aspect.param_names.len & " method name arguments")

  let applied = new_array_value()
  for i in 0..<aspect.param_names.len:
    let param_name = aspect.param_names[i]
    let method_name_val = get_positional_arg(args, i + 2, has_keyword_args)
    var method_name = ""
    case method_name_val.kind
    of VkString, VkSymbol:
      method_name = method_name_val.str
    else:
      not_allowed("method name must be a string or symbol")

    let method_key = method_name.to_key()
    if not class.methods.hasKey(method_key):
      not_allowed("class does not have method: " & method_name)

    let original_method = class.methods[method_key]
    let interception_val = create_interception_value(original_method.callable, self, param_name)
    class.methods[method_key].callable = interception_val
    array_data(applied).add(interception_val)

  return applied

proc aspect_apply_fn(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 3:
    not_allowed("aspect.apply-fn requires self, function, and parameter name")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkAspect:
    not_allowed("apply-fn must be called on an aspect")
  let aspect = self.ref.aspect

  let fn_arg = get_positional_arg(args, 1, has_keyword_args)
  if fn_arg.kind notin {VkFunction, VkNativeFn, VkInterception}:
    not_allowed("aspect.apply-fn requires a function, native function, or interception")

  let param_name_val = get_positional_arg(args, 2, has_keyword_args)
  let param_name = case param_name_val.kind
    of VkString, VkSymbol: param_name_val.str
    else:
      not_allowed("parameter name must be a string or symbol")
      ""

  if not (param_name in aspect.param_names):
    not_allowed("aspect.apply-fn parameter '" & param_name & "' is not defined in aspect")

  create_interception_value(fn_arg, self, param_name)

proc aspect_set_interception_active(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                    has_keyword_args: bool, active: bool): Value {.gcsafe.} =
  if arg_count < 2:
    not_allowed("aspect interception toggle requires self and interception arguments")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkAspect:
    not_allowed("interception toggle must be called on an aspect")

  let interception_val = get_positional_arg(args, 1, has_keyword_args)
  if interception_val.kind != VkInterception:
    not_allowed("interception toggle requires an Interception value")

  if interception_val.ref.interception.aspect != self:
    not_allowed("interception does not belong to this aspect")

  interception_val.ref.interception.active = active
  interception_val

proc aspect_enable_interception(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                has_keyword_args: bool): Value {.gcsafe.} =
  aspect_set_interception_active(vm, args, arg_count, has_keyword_args, true)

proc aspect_disable_interception(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                                 has_keyword_args: bool): Value {.gcsafe.} =
  aspect_set_interception_active(vm, args, arg_count, has_keyword_args, false)

proc init_aspect_support*() =
  var global_ns = App.app.global_ns.ns

  var aspect_macro_ref = new_ref(VkNativeMacro)
  aspect_macro_ref.native_macro = aspect_macro
  global_ns["aspect".to_key()] = aspect_macro_ref.to_ref_value()

  let aspect_class = new_class("Aspect")
  aspect_class.def_native_method("apply", aspect_apply)
  aspect_class.def_native_method("apply-fn", aspect_apply_fn)
  aspect_class.def_native_method("enable-interception", aspect_enable_interception)
  aspect_class.def_native_method("disable-interception", aspect_disable_interception)
  var aspect_class_ref = new_ref(VkClass)
  aspect_class_ref.class = aspect_class
  App.app.aspect_class = aspect_class_ref.to_ref_value()
  App.app.gene_ns.ns["Aspect".to_key()] = App.app.aspect_class
  global_ns["Aspect".to_key()] = App.app.aspect_class
