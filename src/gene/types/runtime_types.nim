## Runtime Type Information and Checking
##
## This module provides runtime type checking utilities that work with
## Gene's NaN-boxed values and the gradual type system.

import tables, strutils, math
import ./type_defs
import ./core

type
  RtTypeKind = enum
    RtAny,
    RtNamed,
    RtUnion,
    RtApplied,
    RtFn

  RtType = ref object
    case kind: RtTypeKind
    of RtAny:
      discard
    of RtNamed:
      name: string
    of RtUnion:
      members: seq[RtType]
    of RtApplied:
      ctor: string
      args: seq[RtType]
    of RtFn:
      params: seq[RtType]
      ret: RtType
      effects: seq[string]

discard # Type cache removed — types resolved at compile time via TypeDesc

proc new_runtime_type_object*(type_id: TypeId, descriptor: TypeDesc): RtTypeObj =
  RtTypeObj(
    type_id: type_id,
    descriptor: descriptor,
    constructor: NIL,
    initializer: NIL,
    methods: initTable[Key, Value](),
    method_hooks: initTable[Key, RtImplLoader]()
  )

proc attach_constructor_hook*(rt: RtTypeObj, hook: RtImplLoader) =
  if rt == nil:
    return
  rt.constructor_hook = hook

proc attach_initializer_hook*(rt: RtTypeObj, hook: RtImplLoader) =
  if rt == nil:
    return
  rt.initializer_hook = hook

proc attach_method_hook*(rt: RtTypeObj, method_key: Key, hook: RtImplLoader) =
  if rt == nil:
    return
  rt.method_hooks[method_key] = hook

proc resolve_constructor*(rt: RtTypeObj): Value =
  if rt == nil:
    return NIL
  if rt.constructor == NIL and rt.constructor_hook != nil:
    rt.constructor = rt.constructor_hook()
  rt.constructor

proc resolve_initializer*(rt: RtTypeObj): Value =
  if rt == nil:
    return NIL
  if rt.initializer == NIL and rt.initializer_hook != nil:
    rt.initializer = rt.initializer_hook()
  rt.initializer

proc resolve_method*(rt: RtTypeObj, method_key: Key): Value =
  if rt == nil:
    return NIL
  if rt.methods.hasKey(method_key):
    return rt.methods[method_key]
  if rt.method_hooks.hasKey(method_key):
    let resolved = rt.method_hooks[method_key]()
    rt.methods[method_key] = resolved
    return resolved
  NIL

proc type_desc_to_rt(type_descs: seq[TypeDesc], type_id: TypeId, depth = 0): RtType =
  if type_id == NO_TYPE_ID:
    return RtType(kind: RtAny)
  if type_id < 0 or type_id.int >= type_descs.len:
    return RtType(kind: RtAny)
  if depth > 64:
    return RtType(kind: RtAny)

  let desc = type_descs[type_id.int]
  case desc.kind
  of TdkAny:
    RtType(kind: RtAny)
  of TdkNamed:
    RtType(kind: RtNamed, name: desc.name)
  of TdkApplied:
    var args: seq[RtType] = @[]
    for arg in desc.args:
      args.add(type_desc_to_rt(type_descs, arg, depth + 1))
    RtType(kind: RtApplied, ctor: desc.ctor, args: args)
  of TdkUnion:
    var members: seq[RtType] = @[]
    for member in desc.members:
      members.add(type_desc_to_rt(type_descs, member, depth + 1))
    RtType(kind: RtUnion, members: members)
  of TdkFn:
    var params: seq[RtType] = @[]
    for param in desc.params:
      params.add(type_desc_to_rt(type_descs, param, depth + 1))
    RtType(
      kind: RtFn,
      params: params,
      ret: type_desc_to_rt(type_descs, desc.ret, depth + 1),
      effects: desc.effects
    )
  of TdkVar:
    RtType(kind: RtAny)

proc type_desc_to_string*(type_id: TypeId, type_descs: seq[TypeDesc], depth = 0): string =
  if type_id == NO_TYPE_ID:
    return "Any"
  if type_id < 0 or type_id.int >= type_descs.len:
    return "Any"
  if depth > 64:
    return "Any"

  let desc = type_descs[type_id.int]
  case desc.kind
  of TdkAny:
    "Any"
  of TdkNamed:
    desc.name
  of TdkApplied:
    var parts: seq[string] = @[desc.ctor]
    for arg in desc.args:
      parts.add(type_desc_to_string(arg, type_descs, depth + 1))
    "(" & parts.join(" ") & ")"
  of TdkUnion:
    var parts: seq[string] = @[]
    for member in desc.members:
      parts.add(type_desc_to_string(member, type_descs, depth + 1))
    "(" & parts.join(" | ") & ")"
  of TdkFn:
    var params: seq[string] = @[]
    for param in desc.params:
      params.add(type_desc_to_string(param, type_descs, depth + 1))
    let ret = type_desc_to_string(desc.ret, type_descs, depth + 1)
    let effects =
      if desc.effects.len > 0: " ! [" & desc.effects.join(" ") & "]"
      else: ""
    "(Fn [" & params.join(" ") & "] " & ret & effects & ")"
  of TdkVar:
    "T" & $desc.var_id

# Runtime type checking using NaN tags
proc is_int*(v: Value): bool {.inline.} =
  ## Check if value is an integer at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == SMALL_INT_TAG

proc is_float*(v: Value): bool {.inline.} =
  ## Check if value is a float at runtime
  # Floats are any non-NaN value in NaN space
  (v.raw and NAN_MASK) != NAN_MASK

proc is_bool*(v: Value): bool {.inline.} =
  ## Check if value is a boolean at runtime
  v == TRUE or v == FALSE

proc is_string*(v: Value): bool {.inline.} =
  ## Check if value is a string at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == STRING_TAG

proc is_symbol*(v: Value): bool {.inline.} =
  ## Check if value is a symbol at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == SYMBOL_TAG

proc is_nil*(v: Value): bool {.inline.} =
  ## Check if value is nil at runtime
  v == NIL

proc is_array*(v: Value): bool {.inline.} =
  ## Check if value is an array at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == ARRAY_TAG

proc is_map*(v: Value): bool {.inline.} =
  ## Check if value is a map at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == MAP_TAG

proc is_instance*(v: Value): bool {.inline.} =
  ## Check if value is a class instance at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == INSTANCE_TAG

proc is_gene*(v: Value): bool {.inline.} =
  ## Check if value is a Gene expression at runtime
  (v.raw and 0xFFFF_0000_0000_0000u64) == GENE_TAG

# Type validation for function calls
proc validate_int*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is an integer, raise exception if not
  if not is_int(v):
    raise new_exception(type_defs.Exception, param_name & " must be Int, got " & $v.kind)

proc validate_float*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is a float, raise exception if not
  if not is_float(v):
    raise new_exception(type_defs.Exception, param_name & " must be Float, got " & $v.kind)

proc validate_bool*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is a boolean, raise exception if not
  if not is_bool(v):
    raise new_exception(type_defs.Exception, param_name & " must be Bool, got " & $v.kind)

proc validate_string*(v: Value, param_name: string = "argument") {.inline.} =
  ## Validate that a value is a string, raise exception if not
  if not is_string(v):
    raise new_exception(type_defs.Exception, param_name & " must be String, got " & $v.kind)

# Get runtime type name as string
proc runtime_type_name*(v: Value): string =
  ## Get the runtime type name of a value
  ## This uses the NaN tag to determine the type
  case v.kind
  of VkInt: "Int"
  of VkFloat: "Float"
  of VkBool: "Bool"
  of VkString: "String"
  of VkSymbol: "Symbol"
  of VkComplexSymbol: "ComplexSymbol"
  of VkNil: "Nil"
  of VkArray: "Array"
  of VkMap: "Map"
  of VkInstance:
    # For instances, try to get the class name
    let inst = cast[ptr InstanceObj](v.raw and PAYLOAD_MASK)
    if inst != nil and inst.instance_class != nil:
      return inst.instance_class.name
    "Instance"
  of VkGene: "Gene"
  of VkFuture: "Future"
  of VkGenerator: "Generator"
  of VkThread: "Thread"
  of VkFunction: "Function"
  of VkBlock: "Block"
  of VkNativeFn: "Function"
  else: $v.kind

proc adt_type_name(value: Value): string =
  if value.kind != VkGene or value.gene == nil:
    return ""
  let gt = value.gene.`type`
  if gt.kind != VkSymbol:
    return ""
  case gt.str
  of "Ok", "Err":
    return "Result"
  of "Some", "None":
    return "Option"
  else:
    return ""

proc is_named_compatible(value: Value, expected_type: string): bool =
  if expected_type == "Any":
    return true
  let actual = runtime_type_name(value)
  if actual == expected_type:
    return true
  let adt = adt_type_name(value)
  if adt.len > 0 and adt == expected_type:
    return true
  case expected_type
  of "Numeric":
    return actual in ["Int", "Float"]
  of "Collection":
    return actual in ["Array", "Map", "Set"]
  of "Function":
    return value.kind in {VkFunction, VkBlock, VkNativeFn}
  else:
    discard
  if value.kind == VkInstance:
    let inst = cast[ptr InstanceObj](value.raw and PAYLOAD_MASK)
    if inst != nil and inst.instance_class != nil:
      var current = inst.instance_class.parent
      while current != nil:
        if current.name == expected_type:
          return true
        current = current.parent
  return false

proc effects_compatible(expected: seq[string], actual: seq[string]): bool =
  if expected.len == 0:
    return actual.len == 0
  if actual.len == 0:
    return true
  for eff in actual:
    var found = false
    for allowed in expected:
      if allowed == eff:
        found = true
        break
    if not found:
      return false
  return true

proc type_expr_compatible(actual: RtType, expected: RtType): bool =
  if actual == nil or expected == nil:
    return true
  if actual.kind == RtAny or expected.kind == RtAny:
    return true
  if expected.kind == RtUnion:
    for member in expected.members:
      if type_expr_compatible(actual, member):
        return true
    return false
  if actual.kind == RtUnion:
    for member in actual.members:
      if not type_expr_compatible(member, expected):
        return false
    return true
  if actual.kind == RtNamed and expected.kind == RtNamed:
    return actual.name == expected.name
  if actual.kind == RtApplied and expected.kind == RtApplied:
    if actual.ctor != expected.ctor:
      return false
    if actual.args.len != expected.args.len:
      return false
    for i in 0..<actual.args.len:
      if not type_expr_compatible(actual.args[i], expected.args[i]):
        return false
    return true
  if actual.kind == RtApplied and expected.kind == RtNamed:
    return actual.ctor == expected.name
  if actual.kind == RtNamed and expected.kind == RtApplied:
    return actual.name == expected.ctor
  if actual.kind == RtFn and expected.kind == RtFn:
    if actual.params.len != expected.params.len:
      return false
    for i in 0..<actual.params.len:
      if not type_expr_compatible(actual.params[i], expected.params[i]):
        return false
    if not type_expr_compatible(actual.ret, expected.ret):
      return false
    if not effects_compatible(expected.effects, actual.effects):
      return false
    return true
  return false

proc function_value_compatible(value: Value, expected: RtType): bool =
  if expected.kind != RtFn:
    return false
  if value.kind == VkNativeFn:
    return true
  let matcher =
    if value.kind == VkFunction: value.ref.fn.matcher
    elif value.kind == VkBlock: value.ref.block.matcher
    else: nil
  if matcher.is_nil:
    return true
  if matcher.children.len != expected.params.len:
    return false
  for i, param in matcher.children:
    let actual_param =
      if param.type_id != NO_TYPE_ID and matcher.type_descriptors.len > 0:
        type_desc_to_rt(matcher.type_descriptors, param.type_id)
      else:
        RtType(kind: RtAny)
    if not type_expr_compatible(actual_param, expected.params[i]):
      return false
  let actual_return =
    if matcher.return_type_id != NO_TYPE_ID and matcher.type_descriptors.len > 0:
      type_desc_to_rt(matcher.type_descriptors, matcher.return_type_id)
    else:
      RtType(kind: RtAny)
  return type_expr_compatible(actual_return, expected.ret)

proc is_compatible_rt(value: Value, expected: RtType): bool =
  case expected.kind
  of RtAny:
    return true
  of RtNamed:
    return is_named_compatible(value, expected.name)
  of RtApplied:
    return is_named_compatible(value, expected.ctor)
  of RtUnion:
    for member in expected.members:
      if is_compatible_rt(value, member):
        return true
    return false
  of RtFn:
    return function_value_compatible(value, expected)

proc is_compatible*(value: Value, expected_type_id: TypeId, type_descs: seq[TypeDesc]): bool =
  if expected_type_id == NO_TYPE_ID:
    return true
  if type_descs.len == 0:
    return true
  let parsed = type_desc_to_rt(type_descs, expected_type_id)
  return is_compatible_rt(value, parsed)

proc types_equivalent*(left_type_id: TypeId, right_type_id: TypeId,
                      type_descs: seq[TypeDesc]): bool =
  ## Structural type equivalence based on runtime compatibility logic.
  ## This is symmetric compatibility over the same descriptor table.
  if type_descs.len == 0:
    return left_type_id == right_type_id
  let left = type_desc_to_rt(type_descs, left_type_id)
  let right = type_desc_to_rt(type_descs, right_type_id)
  return type_expr_compatible(left, right) and type_expr_compatible(right, left)

proc normalize_numeric_type_name(expected_type: string): string =
  case expected_type.toLowerAscii()
  of "int", "int64", "i64":
    return "Int"
  of "float", "float64", "f64":
    return "Float"
  else:
    return expected_type

proc try_convert_named(value: Value, expected_type: string, param_name: string,
                      converted: var Value, warning: var string): bool =
  let normalized = normalize_numeric_type_name(expected_type)
  case normalized
  of "Float":
    if value.kind == VkInt:
      converted = system.float64(value.to_int()).to_value()
      warning = ""
      return true
  of "Int":
    if value.kind == VkFloat:
      let float_value = value.to_float()
      let cls = classify(float_value)
      if cls in {fcNan, fcInf, fcNegInf}:
        return false
      if float_value < system.float64(SMALL_INT_MIN) or float_value > system.float64(SMALL_INT_MAX):
        return false
      let int_value = system.int64(float_value)
      converted = int_value.to_value()
      if system.float64(int_value) != float_value:
        warning = "Lossy conversion Float -> Int for " & param_name &
          ": " & $float_value & " -> " & $int_value
      else:
        warning = ""
      return true
  else:
    discard
  return false

proc try_convert_to_rt(value: Value, expected: RtType, param_name: string,
                      converted: var Value, warning: var string): bool

proc try_convert_union(value: Value, members: seq[RtType], param_name: string,
                      converted: var Value, warning: var string): bool =
  for member in members:
    if is_compatible_rt(value, member):
      converted = value
      warning = ""
      return true

  var has_lossy = false
  var lossy_value = value
  var lossy_warning = ""
  for member in members:
    var candidate = value
    var candidate_warning = ""
    if try_convert_to_rt(value, member, param_name, candidate, candidate_warning):
      if candidate_warning.len == 0:
        converted = candidate
        warning = ""
        return true
      if not has_lossy:
        has_lossy = true
        lossy_value = candidate
        lossy_warning = candidate_warning

  if has_lossy:
    converted = lossy_value
    warning = lossy_warning
    return true
  return false

proc try_convert_to_rt(value: Value, expected: RtType, param_name: string,
                      converted: var Value, warning: var string): bool =
  if expected == nil:
    converted = value
    warning = ""
    return true
  if is_compatible_rt(value, expected):
    converted = value
    warning = ""
    return true

  case expected.kind
  of RtAny:
    converted = value
    warning = ""
    return true
  of RtNamed:
    return try_convert_named(value, expected.name, param_name, converted, warning)
  of RtApplied:
    return try_convert_named(value, expected.ctor, param_name, converted, warning)
  of RtUnion:
    return try_convert_union(value, expected.members, param_name, converted, warning)
  of RtFn:
    return false

proc coerce_value_to_type*(value: Value, expected_type_id: TypeId, type_descs: seq[TypeDesc],
                          param_name: string, converted: var Value,
                          warning: var string): bool =
  if expected_type_id == NO_TYPE_ID or type_descs.len == 0:
    converted = value
    warning = ""
    return true
  let parsed = type_desc_to_rt(type_descs, expected_type_id)
  return try_convert_to_rt(value, parsed, param_name, converted, warning)

proc emit_type_warning*(warning: string) =
  if warning.len > 0:
    stderr.writeLine("Warning: " & warning)

proc validate_or_coerce_type*(value: var Value, expected_type_id: TypeId,
                             type_descs: seq[TypeDesc],
                             param_name: string = "argument"): string =
  var converted = value
  var warning = ""
  if coerce_value_to_type(value, expected_type_id, type_descs, param_name, converted, warning):
    value = converted
    return warning
  let actual = runtime_type_name(value)
  let expected = type_desc_to_string(expected_type_id, type_descs)
  raise new_exception(type_defs.Exception,
    "Type error: expected " & expected & ", got " & actual & " in " & param_name)

proc validate_type*(value: Value, expected_type_id: TypeId, type_descs: seq[TypeDesc],
                   param_name: string = "argument") =
  if not is_compatible(value, expected_type_id, type_descs):
    let actual = runtime_type_name(value)
    let expected = type_desc_to_string(expected_type_id, type_descs)
    raise new_exception(type_defs.Exception,
      "Type error: expected " & expected & ", got " & actual & " in " & param_name)
