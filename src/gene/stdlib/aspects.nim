import tables

import ../types

const
  InterceptFnArityMarker = "[GENE.INTERCEPT.FN_ARITY]"
  InterceptKeywordUnsupportedMarker = "[GENE.INTERCEPT.KEYWORD_UNSUPPORTED]"
  InterceptFnTargetMarker = "[GENE.INTERCEPT.FN_TARGET]"
  InterceptMacroUnsupportedMarker = "[GENE.INTERCEPT.MACRO_UNSUPPORTED]"
  InterceptAsyncUnsupportedMarker = "[GENE.INTERCEPT.ASYNC_UNSUPPORTED]"

proc interception_application_label(label: string, aspect_name: string): string =
  if aspect_name.len > 0:
    label & " '" & aspect_name & "'"
  else:
    label

proc raise_interception_diagnostic(marker: string, label: string, aspect_name: string, detail: string) =
  not_allowed(marker & " " & interception_application_label(label, aspect_name) & ": " & detail)

proc matcher_name(matcher: Matcher): string =
  if matcher != nil and matcher.name_key != Key(0):
    try:
      return cast[Value](matcher.name_key).str
    except CatchableError:
      discard
  "<keyword>"

proc function_keyword_param_name(fn: Function): string =
  if fn != nil and fn.matcher != nil:
    for matcher in fn.matcher.children:
      if matcher.kind == MatchProp or matcher.is_prop:
        return matcher_name(matcher)
  ""

proc function_target_kind(fn_arg: Value): string =
  case fn_arg.kind
  of VkFunction:
    let fn = fn_arg.ref.fn
    if fn.is_macro_like:
      "macro-like function"
    elif fn.async:
      "async function"
    elif function_keyword_param_name(fn).len > 0:
      "function with keyword parameters"
    else:
      "function"
  of VkNativeFn:
    "native function"
  of VkNativeMacro:
    "native macro"
  of VkInterception:
    "interception"
  of VkClass:
    "class"
  else:
    $fn_arg.kind

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
    var resolved = NIL
    if caller_frame != nil and caller_frame.scope != nil and caller_frame.scope.tracker != nil:
      let found = caller_frame.scope.tracker.locate(key)
      if found.local_index >= 0:
        var scope = caller_frame.scope
        var parent_index = found.parent_index
        while parent_index > 0 and scope != nil:
          parent_index.dec()
          scope = scope.parent
        if scope != nil and found.local_index < scope.members.len:
          resolved = scope.members[found.local_index]
    if resolved == NIL:
      resolved = if caller_frame.ns != nil: caller_frame.ns[key] else: NIL
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

proc parse_aspect_macro(form_label: string, definition_kind: AspectDefinitionKind,
                        vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let gene = gene_value.gene
    if gene.children.len < 2:
      not_allowed(form_label & " requires a name and method parameters")

    let name_val = gene.children[0]
    if name_val.kind != VkSymbol:
      not_allowed(form_label & " name must be a symbol")
    let name = name_val.str

    let params_val = gene.children[1]
    if params_val.kind != VkArray:
      not_allowed(form_label & " parameter list must be an array")

    var param_names: seq[string] = @[]
    for p in array_data(params_val):
      if p.kind == VkSymbol:
        param_names.add(p.str)
      else:
        not_allowed(form_label & " parameter must be a symbol")

    if definition_kind == AkFunctionInterceptor and param_names.len != 1:
      not_allowed("fn-interceptor parameter list must contain exactly one symbol")

    let aspect = Aspect(
      name: name,
      definition_kind: definition_kind,
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
        not_allowed(form_label & " advice definition must be a gene expression")

      let advice_gene = advice_def.gene
      if advice_gene.children.len < 2:
        not_allowed(form_label & " advice requires type and target")

      let advice_type = advice_gene.type
      if advice_type.kind != VkSymbol:
        not_allowed(form_label & " advice type must be a symbol")
      let advice_type_str = advice_type.str

      var replace_result = false
      let replace_key = "replace_result".to_key()
      if advice_gene.props.has_key(replace_key):
        let replace_val = advice_gene.props[replace_key]
        replace_result = (replace_val == NIL or replace_val == PLACEHOLDER) or replace_val.to_bool()
        if replace_result and advice_type_str != "after":
          not_allowed("replace_result is only allowed for after " & form_label & " advices")

      let target = advice_gene.children[0]
      if target.kind != VkSymbol:
        not_allowed(form_label & " advice target must be a method parameter symbol")
      let target_name = target.str

      if not (target_name in param_names):
        not_allowed(form_label & " advice target '" & target_name & "' is not a defined method parameter")

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

        let parent_tracker =
          if caller_frame != nil and caller_frame.scope != nil:
            caller_frame.scope.tracker
          else:
            nil
        var scope_tracker =
          if parent_tracker != nil:
            new_scope_tracker(parent_tracker)
          else:
            new_scope_tracker()
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
        not_allowed("unknown " & form_label & " advice type: " & advice_type_str)

    let aspect_ref = new_ref(VkAspect)
    aspect_ref.aspect = aspect
    let aspect_val = aspect_ref.to_ref_value()

    caller_frame.ns[name.to_key()] = aspect_val

    return aspect_val

proc aspect_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  parse_aspect_macro("aspect", AkLegacyAspect, vm, gene_value, caller_frame)

proc interceptor_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  parse_aspect_macro("interceptor", AkClassInterceptor, vm, gene_value, caller_frame)

proc fn_interceptor_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  parse_aspect_macro("fn-interceptor", AkFunctionInterceptor, vm, gene_value, caller_frame)

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

proc apply_aspect_to_class(label: string, self: Value, class_arg: Value, method_name_vals: seq[Value]): Value =
  if self.kind != VkAspect:
    not_allowed(label & " must be called on an aspect")

  let aspect = self.ref.aspect

  if class_arg.kind != VkClass:
    not_allowed(label & " requires a class argument")

  let class = class_arg.ref.class

  if method_name_vals.len != aspect.param_names.len:
    not_allowed(label & " requires " & $aspect.param_names.len & " method name arguments")

  let applied = new_array_value()
  for i in 0..<aspect.param_names.len:
    let param_name = aspect.param_names[i]
    let method_name_val = method_name_vals[i]
    var method_name = ""
    case method_name_val.kind
    of VkString, VkSymbol:
      method_name = method_name_val.str
    else:
      not_allowed(label & " method name must be a string or symbol")

    let method_key = method_name.to_key()
    if not class.methods.hasKey(method_key):
      not_allowed(label & " class does not have method: " & method_name)

    let original_method = class.methods[method_key]
    let interception_val = create_interception_value(original_method.callable, self, param_name)
    class.methods[method_key].callable = interception_val
    class.version.inc()
    if class.runtime_type != nil:
      class.runtime_type.methods[method_key] = interception_val
    array_data(applied).add(interception_val)

  return applied

proc validate_function_interceptor_target(label: string, aspect_name: string, fn_arg: Value) =
  case fn_arg.kind
  of VkFunction:
    let fn = fn_arg.ref.fn
    if fn.is_macro_like:
      raise_interception_diagnostic(
        InterceptMacroUnsupportedMarker,
        label,
        aspect_name,
        "expected non-macro callable target; actual " & function_target_kind(fn_arg) &
          " '" & fn.name & "'"
      )
    if fn.async:
      raise_interception_diagnostic(
        InterceptAsyncUnsupportedMarker,
        label,
        aspect_name,
        "expected synchronous callable target; actual async function '" & fn.name & "'"
      )
    let keyword_name = function_keyword_param_name(fn)
    if keyword_name.len > 0:
      raise_interception_diagnostic(
        InterceptKeywordUnsupportedMarker,
        label,
        aspect_name,
        "target function '" & fn.name & "' declares keyword parameter '" & keyword_name &
          "', but keyword forwarding is deferred"
      )
  of VkNativeFn, VkInterception:
    discard
  of VkNativeMacro:
    raise_interception_diagnostic(
      InterceptMacroUnsupportedMarker,
      label,
      aspect_name,
      "expected non-macro callable target; actual " & function_target_kind(fn_arg)
    )
  else:
    raise_interception_diagnostic(
      InterceptFnTargetMarker,
      label,
      aspect_name,
      "expected function, native function, or interception target; actual " & function_target_kind(fn_arg)
    )

proc apply_aspect_to_function(label: string, self: Value, fn_arg: Value): Value =
  if self.kind != VkAspect:
    not_allowed(label & " must be called on an aspect")

  let aspect = self.ref.aspect
  if aspect.param_names.len != 1:
    raise_interception_diagnostic(
      InterceptFnArityMarker,
      label,
      aspect.name,
      "expected exactly one function parameter in interceptor definition; actual " & $aspect.param_names.len
    )

  validate_function_interceptor_target(label, aspect.name, fn_arg)

  create_interception_value(fn_arg, self, aspect.param_names[0])

proc collect_method_name_args(label: string, args: ptr UncheckedArray[Value], arg_count: int,
                              has_keyword_args: bool): seq[Value] =
  if has_keyword_args:
    not_allowed(label & " does not accept keyword arguments")

  if arg_count < 2:
    not_allowed(label & " requires self and class arguments")

  let positional = get_positional_count(arg_count, has_keyword_args)
  for i in 2..<positional:
    result.add(get_positional_arg(args, i, has_keyword_args))

proc aspect_apply(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let method_name_vals = collect_method_name_args("aspect.apply", args, arg_count, has_keyword_args)
  let self = get_positional_arg(args, 0, has_keyword_args)
  let class_arg = get_positional_arg(args, 1, has_keyword_args)
  apply_aspect_to_class("aspect.apply", self, class_arg, method_name_vals)

proc aspect_call(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkAspect:
    not_allowed("aspect call must be called on an aspect")

  let aspect = self.ref.aspect
  case aspect.definition_kind
  of AkFunctionInterceptor:
    if has_keyword_args:
      raise_interception_diagnostic(
        InterceptKeywordUnsupportedMarker,
        "fn-interceptor application",
        aspect.name,
        "direct application does not accept keyword arguments"
      )
    let positional = get_positional_count(arg_count, has_keyword_args)
    if positional != 2:
      raise_interception_diagnostic(
        InterceptFnArityMarker,
        "fn-interceptor application",
        aspect.name,
        "expected exactly one callable argument; actual " & $(positional - 1)
      )
    let fn_arg = get_positional_arg(args, 1, has_keyword_args)
    apply_aspect_to_function("fn-interceptor application", self, fn_arg)
  of AkLegacyAspect, AkClassInterceptor:
    let method_name_vals = collect_method_name_args("interceptor application", args, arg_count, has_keyword_args)
    let class_arg = get_positional_arg(args, 1, has_keyword_args)
    apply_aspect_to_class("interceptor application", self, class_arg, method_name_vals)

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

proc toggle_receiver(label: string, args: ptr UncheckedArray[Value], arg_count: int,
                     has_keyword_args: bool): Value {.gcsafe.} =
  if has_keyword_args:
    not_allowed(label & " does not accept keyword arguments")
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional != 1:
    not_allowed(label & " expects no arguments")
  get_positional_arg(args, 0, has_keyword_args)

proc aspect_set_enabled(label: string, args: ptr UncheckedArray[Value], arg_count: int,
                        has_keyword_args: bool, enabled: bool): Value {.gcsafe.} =
  let self = toggle_receiver(label, args, arg_count, has_keyword_args)
  if self.kind != VkAspect:
    not_allowed(label & " must be called on an aspect")
  self.ref.aspect.enabled = enabled
  self

proc aspect_enable(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                   has_keyword_args: bool): Value {.gcsafe.} =
  aspect_set_enabled("Aspect.enable", args, arg_count, has_keyword_args, true)

proc aspect_disable(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                    has_keyword_args: bool): Value {.gcsafe.} =
  aspect_set_enabled("Aspect.disable", args, arg_count, has_keyword_args, false)

proc interception_set_active(label: string, args: ptr UncheckedArray[Value], arg_count: int,
                             has_keyword_args: bool, active: bool): Value {.gcsafe.} =
  let self = toggle_receiver(label, args, arg_count, has_keyword_args)
  if self.kind != VkInterception:
    not_allowed(label & " must be called on an Interception")
  self.ref.interception.active = active
  self

proc interception_enable(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                         has_keyword_args: bool): Value {.gcsafe.} =
  interception_set_active("Interception.enable", args, arg_count, has_keyword_args, true)

proc interception_disable(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                          has_keyword_args: bool): Value {.gcsafe.} =
  interception_set_active("Interception.disable", args, arg_count, has_keyword_args, false)

proc init_aspect_support*() =
  var global_ns = App.app.global_ns.ns

  var aspect_macro_ref = new_ref(VkNativeMacro)
  aspect_macro_ref.native_macro = aspect_macro
  global_ns["aspect".to_key()] = aspect_macro_ref.to_ref_value()

  var interceptor_macro_ref = new_ref(VkNativeMacro)
  interceptor_macro_ref.native_macro = interceptor_macro
  global_ns["interceptor".to_key()] = interceptor_macro_ref.to_ref_value()

  var fn_interceptor_macro_ref = new_ref(VkNativeMacro)
  fn_interceptor_macro_ref.native_macro = fn_interceptor_macro
  global_ns["fn-interceptor".to_key()] = fn_interceptor_macro_ref.to_ref_value()

  let aspect_class = new_class("Aspect")
  if App.app.object_class.kind == VkClass:
    aspect_class.parent = App.app.object_class.ref.class
  aspect_class.def_native_method("apply", aspect_apply)
  aspect_class.def_native_method("call", aspect_call)
  aspect_class.def_native_method("apply-fn", aspect_apply_fn)
  aspect_class.def_native_method("enable", aspect_enable)
  aspect_class.def_native_method("disable", aspect_disable)
  aspect_class.def_native_method("enable-interception", aspect_enable_interception)
  aspect_class.def_native_method("disable-interception", aspect_disable_interception)
  var aspect_class_ref = new_ref(VkClass)
  aspect_class_ref.class = aspect_class
  App.app.aspect_class = aspect_class_ref.to_ref_value()
  App.app.gene_ns.ns["Aspect".to_key()] = App.app.aspect_class
  App.app.gene_ns.ns["Interceptor".to_key()] = App.app.aspect_class
  global_ns["Aspect".to_key()] = App.app.aspect_class
  global_ns["Interceptor".to_key()] = App.app.aspect_class

  let interception_class = new_class("Interception")
  if App.app.object_class.kind == VkClass:
    interception_class.parent = App.app.object_class.ref.class
  interception_class.def_native_method("enable", interception_enable)
  interception_class.def_native_method("disable", interception_disable)
  var interception_class_ref = new_ref(VkClass)
  interception_class_ref.class = interception_class
  App.app.interception_class = interception_class_ref.to_ref_value()
  App.app.gene_ns.ns["Interception".to_key()] = App.app.interception_class
  global_ns["Interception".to_key()] = App.app.interception_class
