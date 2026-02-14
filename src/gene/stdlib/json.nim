import std/json as nim_json
import strutils, tables

import ../types

proc parse_json_node(node: nim_json.JsonNode): Value {.gcsafe.}

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

  var json_parse_fn = new_ref(VkNativeFn)
  json_parse_fn.native_fn = json_parse_native
  var json_stringify_fn = new_ref(VkNativeFn)
  json_stringify_fn.native_fn = json_stringify_native
  let json_ns = new_namespace("json")
  json_ns["parse".to_key()] = json_parse_fn.to_ref_value()
  json_ns["stringify".to_key()] = json_stringify_fn.to_ref_value()
  App.app.gene_ns.ns["json".to_key()] = json_ns.to_value()
