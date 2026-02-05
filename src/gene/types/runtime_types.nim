## Runtime Type Information and Checking
##
## This module provides runtime type checking utilities that work with
## Gene's NaN-boxed values and the gradual type system.

import tables, strutils
import ./type_defs
import ./value_core

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

var rt_type_cache_initialized {.threadvar.}: bool
var rt_type_cache {.threadvar.}: Table[string, RtType]

proc ensure_rt_type_cache() =
  if not rt_type_cache_initialized:
    rt_type_cache = initTable[string, RtType]()
    rt_type_cache_initialized = true

proc is_delim(c: char): bool {.inline.} =
  c.isSpaceAscii or c in {'(', ')', '[', ']', '|'}

proc skip_ws(s: string, i: var int) {.inline.} =
  while i < s.len and s[i].isSpaceAscii:
    i.inc

proc parse_symbol(s: string, i: var int): string =
  skip_ws(s, i)
  let start = i
  while i < s.len and not is_delim(s[i]):
    i.inc
  if i > start:
    return s[start..<i]
  return ""

proc parse_type_expr(s: string, i: var int): RtType

proc parse_type_atom(s: string, i: var int): RtType =
  skip_ws(s, i)
  if i >= s.len:
    return RtType(kind: RtAny)
  if s[i] == '(':
    i.inc
    skip_ws(s, i)
    if i < s.len and s[i] != '(':
      let sym = parse_symbol(s, i)
      if sym == "Fn":
        skip_ws(s, i)
        if i < s.len and s[i] == '[':
          i.inc
        var params: seq[RtType] = @[]
        while i < s.len:
          skip_ws(s, i)
          if i < s.len and s[i] == ']':
            i.inc
            break
          if i < s.len and s[i] == '^':
            i.inc
            discard parse_symbol(s, i)
            params.add(parse_type_expr(s, i))
          else:
            params.add(parse_type_expr(s, i))
        let ret_type = parse_type_expr(s, i)
        skip_ws(s, i)
        if i < s.len and s[i] == ')':
          i.inc
        return RtType(kind: RtFn, params: params, ret: ret_type)
      elif sym.len > 0:
        var parts: seq[RtType] = @[RtType(kind: RtNamed, name: sym)]
        var union_mode = false
        while i < s.len:
          skip_ws(s, i)
          if i >= s.len:
            break
          if s[i] == ')':
            i.inc
            break
          if s[i] == '|':
            union_mode = true
            i.inc
            continue
          parts.add(parse_type_expr(s, i))
        if union_mode:
          return RtType(kind: RtUnion, members: parts)
        if parts.len == 1:
          return parts[0]
        return RtType(kind: RtApplied, ctor: parts[0].name, args: parts[1..^1])
    var parts: seq[RtType] = @[parse_type_expr(s, i)]
    var union_mode = false
    while i < s.len:
      skip_ws(s, i)
      if i >= s.len:
        break
      if s[i] == ')':
        i.inc
        break
      if s[i] == '|':
        union_mode = true
        i.inc
        continue
      parts.add(parse_type_expr(s, i))
    if union_mode:
      return RtType(kind: RtUnion, members: parts)
    if parts.len == 1:
      return parts[0]
    if parts[0].kind == RtNamed:
      return RtType(kind: RtApplied, ctor: parts[0].name, args: parts[1..^1])
    return parts[0]
  if s[i] == '[':
    i.inc
    skip_ws(s, i)
    var parts: seq[RtType] = @[]
    while i < s.len and s[i] != ']':
      parts.add(parse_type_expr(s, i))
      skip_ws(s, i)
    if i < s.len and s[i] == ']':
      i.inc
    if parts.len == 1:
      return parts[0]
    return RtType(kind: RtAny)
  let name = parse_symbol(s, i)
  if name.len == 0:
    return RtType(kind: RtAny)
  if name == "Any":
    return RtType(kind: RtAny)
  return RtType(kind: RtNamed, name: name)

proc parse_type_expr(s: string, i: var int): RtType =
  return parse_type_atom(s, i)

proc parse_expected_type(expected_type: string): RtType =
  if expected_type.len == 0:
    return RtType(kind: RtAny)
  ensure_rt_type_cache()
  if rt_type_cache.hasKey(expected_type):
    return rt_type_cache[expected_type]
  var idx = 0
  var parsed = parse_type_expr(expected_type, idx)
  if parsed == nil:
    parsed = RtType(kind: RtNamed, name: expected_type)
  rt_type_cache[expected_type] = parsed
  return parsed

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
    return actual.ctor == expected.ctor
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
    return type_expr_compatible(actual.ret, expected.ret)
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
      if param.type_name.len > 0: parse_expected_type(param.type_name) else: RtType(kind: RtAny)
    if not type_expr_compatible(actual_param, expected.params[i]):
      return false
  let actual_return =
    if matcher.return_type_name.len > 0: parse_expected_type(matcher.return_type_name) else: RtType(kind: RtAny)
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

# Type compatibility checking for gradual typing
proc is_compatible*(value: Value, expected_type: string): bool =
  if expected_type.len == 0:
    return true
  let parsed = parse_expected_type(expected_type)
  return is_compatible_rt(value, parsed)

proc validate_type*(value: Value, expected_type: string, param_name: string = "argument") =
  ## Validate that a value is compatible with an expected type
  ## Raises a Gene exception if not compatible (catchable by Gene try/catch)
  if not is_compatible(value, expected_type):
    let actual = runtime_type_name(value)
    raise new_exception(type_defs.Exception,
      "Type error: expected " & expected_type & ", got " & actual & " in " & param_name)
