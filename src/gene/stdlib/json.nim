import std/json as nim_json
import algorithm, strutils, tables

import ../types
import ../parser

proc parse_json_node(node: nim_json.JsonNode): Value {.gcsafe.}

const
  GENE_JSON_TAG_PREFIX = "#GENE#"
  JSON_GENETYPE_KEY = "genetype"
  JSON_CHILDREN_KEY = "children"
  JSON_SAFE_INT_MAX = 9_007_199_254_740_991'i64
  JSON_SAFE_INT_MIN = -9_007_199_254_740_991'i64

proc parse_json_node(node: nim_json.JsonNode): Value {.gcsafe.} =
  case node.kind
  of nim_json.JNull:
    return NIL
  of nim_json.JBool:
    return node.bval.to_value()
  of nim_json.JInt:
    return int64(node.num).to_value()
  of nim_json.JFloat:
    return node.fnum.to_value()
  of nim_json.JString:
    return node.str.to_value()
  of nim_json.JObject:
    var map_table = initTable[Key, Value]()
    for k, v in node.fields:
      map_table[to_key(k)] = parse_json_node(v)
    return new_map_value(map_table)
  of nim_json.JArray:
    var arr_ref = new_array_value()
    for elem in node.elems:
      array_data(arr_ref).add(parse_json_node(elem))
    return arr_ref

proc parse_json_string*(json_str: string): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let parsed = nim_json.parseJson(json_str)
    return parse_json_node(parsed)

proc tagged_gene_literal_to_value(payload: string): Value {.gcsafe.} =
  try:
    let values = read_all(payload)
    if values.len != 1:
      not_allowed("Tagged Gene JSON payload must contain exactly one Gene value")
    values[0]
  except ParseError as e:
    raise new_exception(types.Exception, "Invalid tagged Gene JSON payload: " & e.msg)

proc gene_value_to_literal(val: Value): string {.gcsafe.}

proc gene_value_to_literal(val: Value): string {.gcsafe.} =
  case val.kind
  of VkNil:
    "nil"
  of VkBool:
    if val.to_bool: "true" else: "false"
  of VkInt:
    $val.to_int
  of VkFloat:
    $val.to_float
  of VkString:
    nim_json.escapeJson(val.str)
  of VkSymbol:
    val.str
  of VkComplexSymbol:
    val.ref.csymbol.join("/")
  of VkArray:
    var items: seq[string] = @[]
    for item in array_data(val):
      items.add(gene_value_to_literal(item))
    "[" & items.join(" ") & "]"
  of VkMap:
    var entries: seq[(string, Value)] = @[]
    for key, value in map_data(val):
      entries.add((cast[Value](key).str, value))
    entries.sort(proc(a, b: (string, Value)): int = cmp(a[0], b[0]))

    var items: seq[string] = @[]
    for (key, value) in entries:
      items.add("^" & key & " " & gene_value_to_literal(value))
    "{" & items.join(" ") & "}"
  of VkGene:
    var segments: seq[string] = @[gene_value_to_literal(val.gene.type)]
    var props: seq[(string, Value)] = @[]
    for key, value in val.gene.props:
      props.add((cast[Value](key).str, value))
    props.sort(proc(a, b: (string, Value)): int = cmp(a[0], b[0]))

    for (key, value) in props:
      segments.add("^" & key & " " & gene_value_to_literal(value))
    for child in val.gene.children:
      segments.add(gene_value_to_literal(child))
    "(" & segments.join(" ") & ")"
  else:
    not_allowed("Tagged Gene JSON does not support " & $val.kind)
    ""

proc tagged_string_value(val: Value): nim_json.JsonNode {.gcsafe.} =
  nim_json.newJString(GENE_JSON_TAG_PREFIX & gene_value_to_literal(val))

proc value_to_tagged_json_node(val: Value): nim_json.JsonNode {.gcsafe.}

proc value_to_tagged_json_node(val: Value): nim_json.JsonNode {.gcsafe.} =
  case val.kind
  of VkNil:
    return nim_json.newJNull()
  of VkBool:
    return nim_json.newJBool(val.to_bool)
  of VkInt:
    let value = val.to_int
    if value < JSON_SAFE_INT_MIN or value > JSON_SAFE_INT_MAX:
      return tagged_string_value(val)
    else:
      return nim_json.newJInt(value)
  of VkFloat:
    return nim_json.newJFloat(val.to_float)
  of VkString:
    if val.str.startsWith(GENE_JSON_TAG_PREFIX):
      return tagged_string_value(val)
    else:
      return nim_json.newJString(val.str)
  of VkSymbol, VkComplexSymbol:
    return tagged_string_value(val)
  of VkArray:
    result = nim_json.newJArray()
    for item in array_data(val):
      result.add(value_to_tagged_json_node(item))
  of VkMap:
    result = nim_json.newJObject()
    var entries: seq[(string, Value)] = @[]
    for key, value in map_data(val):
      let key_name = cast[Value](key).str
      if key_name == JSON_GENETYPE_KEY:
        not_allowed("Tagged Gene JSON cannot serialize a map with key 'genetype'")
      entries.add((key_name, value))
    entries.sort(proc(a, b: (string, Value)): int = cmp(a[0], b[0]))
    for (key, value) in entries:
      result[key] = value_to_tagged_json_node(value)
  of VkGene:
    result = nim_json.newJObject()
    result[JSON_GENETYPE_KEY] = value_to_tagged_json_node(val.gene.type)

    var props: seq[(string, Value)] = @[]
    for key, value in val.gene.props:
      let key_name = cast[Value](key).str
      if key_name == JSON_GENETYPE_KEY or key_name == JSON_CHILDREN_KEY:
        not_allowed("Tagged Gene JSON cannot serialize a Gene with reserved prop '" & key_name & "'")
      props.add((key_name, value))
    props.sort(proc(a, b: (string, Value)): int = cmp(a[0], b[0]))

    for (key, value) in props:
      result[key] = value_to_tagged_json_node(value)

    if val.gene.children.len > 0:
      let children = nim_json.newJArray()
      for child in val.gene.children:
        children.add(value_to_tagged_json_node(child))
      result[JSON_CHILDREN_KEY] = children
  else:
    not_allowed("Tagged Gene JSON does not support " & $val.kind)
    return nim_json.newJNull()

proc parse_tagged_json_node(node: nim_json.JsonNode): Value {.gcsafe.}

proc parse_tagged_json_node(node: nim_json.JsonNode): Value {.gcsafe.} =
  case node.kind
  of nim_json.JNull:
    return NIL
  of nim_json.JBool:
    return node.bval.to_value()
  of nim_json.JInt:
    return int64(node.num).to_value()
  of nim_json.JFloat:
    return node.fnum.to_value()
  of nim_json.JString:
    if node.str.startsWith(GENE_JSON_TAG_PREFIX):
      return tagged_gene_literal_to_value(node.str[GENE_JSON_TAG_PREFIX.len .. ^1])
    else:
      return node.str.to_value()
  of nim_json.JObject:
    if node.hasKey(JSON_GENETYPE_KEY):
      let gene = new_gene(parse_tagged_json_node(node[JSON_GENETYPE_KEY]))
      for key, value in node.fields:
        if key == JSON_GENETYPE_KEY:
          continue
        if key == JSON_CHILDREN_KEY:
          if value.kind != nim_json.JArray:
            not_allowed("Tagged Gene JSON 'children' must be an array")
          for child in value.elems:
            gene.children.add(parse_tagged_json_node(child))
        else:
          gene.props[key.to_key()] = parse_tagged_json_node(value)
      return gene.to_gene_value()
    else:
      var map_table = initTable[Key, Value]()
      for key, value in node.fields:
        map_table[key.to_key()] = parse_tagged_json_node(value)
      return new_map_value(map_table)
  of nim_json.JArray:
    var arr_ref = new_array_value()
    for elem in node.elems:
      array_data(arr_ref).add(parse_tagged_json_node(elem))
    return arr_ref

proc parse_tagged_json_string*(json_str: string): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let parsed = nim_json.parseJson(json_str)
    return parse_tagged_json_node(parsed)

proc value_to_json*(val: Value): string {.gcsafe.} =
  case val.kind
  of VkNil:
    result = "null"
  of VkBool:
    result = if val.to_bool: "true" else: "false"
  of VkInt:
    result = $val.to_int
  of VkFloat:
    result = $val.to_float
  of VkString:
    result = nim_json.escapeJson(val.str)
  of VkSymbol:
    result = nim_json.escapeJson(val.str)
  of VkArray:
    var items: seq[string] = @[]
    for item in array_data(val):
      items.add(value_to_json(item))
    result = "[" & items.join(",") & "]"
  of VkMap:
    var items: seq[string] = @[]
    for k, v in map_data(val):
      let key_val = cast[Value](k)
      let key_str =
        case key_val.kind
        of VkSymbol, VkString:
          key_val.str
        of VkInt:
          $key_val.to_int
        of VkFloat:
          $key_val.to_float
        else:
          $key_val
      items.add(nim_json.escapeJson(key_str) & ":" & value_to_json(v))
    result = "{" & items.join(",") & "}"
  else:
    result = nim_json.escapeJson($val)

proc value_to_tagged_json*(val: Value): string {.gcsafe.} =
  $value_to_tagged_json_node(val)

proc init_json_namespace*() =
  proc json_parse_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("json.parse requires a string argument")
    let json_arg = get_positional_arg(args, 0, has_keyword_args)
    if json_arg.kind != VkString:
      not_allowed("json.parse expects a string")
    try:
      {.cast(gcsafe).}:
        return parse_json_string(json_arg.str)
    except nim_json.JsonParsingError as e:
      raise new_exception(types.Exception, "Invalid JSON: " & e.msg)

  proc json_stringify_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("json.stringify requires a value")
    let value_arg = get_positional_arg(args, 0, has_keyword_args)
    value_to_json(value_arg).to_value()

  proc json_serialize_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("json.serialize requires a value")
    let value_arg = get_positional_arg(args, 0, has_keyword_args)
    value_to_tagged_json(value_arg).to_value()

  proc json_deserialize_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("json.deserialize requires a string argument")
    let json_arg = get_positional_arg(args, 0, has_keyword_args)
    if json_arg.kind != VkString:
      not_allowed("json.deserialize expects a string")
    try:
      {.cast(gcsafe).}:
        return parse_tagged_json_string(json_arg.str)
    except nim_json.JsonParsingError as e:
      raise new_exception(types.Exception, "Invalid JSON: " & e.msg)

  var json_parse_fn = new_ref(VkNativeFn)
  json_parse_fn.native_fn = json_parse_native
  var json_stringify_fn = new_ref(VkNativeFn)
  json_stringify_fn.native_fn = json_stringify_native
  var json_serialize_fn = new_ref(VkNativeFn)
  json_serialize_fn.native_fn = json_serialize_native
  var json_deserialize_fn = new_ref(VkNativeFn)
  json_deserialize_fn.native_fn = json_deserialize_native
  let json_ns = new_namespace("json")
  json_ns["parse".to_key()] = json_parse_fn.to_ref_value()
  json_ns["stringify".to_key()] = json_stringify_fn.to_ref_value()
  json_ns["serialize".to_key()] = json_serialize_fn.to_ref_value()
  json_ns["deserialize".to_key()] = json_deserialize_fn.to_ref_value()
  App.app.gene_ns.ns["json".to_key()] = json_ns.to_value()
