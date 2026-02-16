{.push warning[ResultShadowed]: off.}
import base64, re, osproc, os, strutils, times, asyncdispatch, asyncfile, tables
import std/json as nim_json
import ../types
from ../types/runtime_types import coerce_value_to_type, emit_type_warning, runtime_type_name, types_equivalent
import ../parser
import ../compiler
import ../repl_session
import ../vm/thread
import ../logging_core
import ./math as stdlib_math
import ./io as stdlib_io
import ./system as stdlib_system
import ./classes as stdlib_classes
import ./regex as stdlib_regex
import ./json as stdlib_json
import ./strings as stdlib_strings
import ./collections as stdlib_collections
import ./dates as stdlib_dates
import ./selectors as stdlib_selectors
import ./gene_meta as stdlib_gene_meta
import ./aspects as stdlib_aspects
import ../../genex/ai/ai

# Note: Extensions register their poll handlers via register_scheduler_callback
# This avoids direct dependency from core to extensions like HTTP

proc display_value(val: Value; topLevel: bool): string {.gcsafe.} =
  case val.kind
  of VkNil:
    if topLevel:
      ""
    else:
      "nil"
  of VkString:
    if topLevel:
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

proc value_class_value(val: Value): Value =
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

proc object_class_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    return App.app.object_class
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  result = value_class_value(self_arg)

proc object_to_s_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    return "".to_value()
  let self_arg = get_positional_arg(args, 0, has_keyword_args)
  display_value(self_arg, true).to_value()

proc object_is_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
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

proc object_to_method(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
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
      # Non-builtin type name — attempt named type desc coercion
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

proc init_basic_classes(): Class =
  # Initialize Object, Nil, Bool, Int, Float classes
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
  int_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = int_class
  App.app.int_class = r.to_ref_value()
  App.app.gene_ns.ns["Int".to_key()] = App.app.int_class
  App.app.global_ns.ns["Int".to_key()] = App.app.int_class

  let float_class = new_class("Float")
  float_class.parent = object_class
  float_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = float_class
  App.app.float_class = r.to_ref_value()
  App.app.gene_ns.ns["Float".to_key()] = App.app.float_class
  App.app.global_ns.ns["Float".to_key()] = App.app.float_class

  object_class

proc value_to_json(val: Value): string {.gcsafe.}
proc build_regex_flags(ignore_case: bool, multiline: bool): uint8 {.inline, gcsafe.}
proc get_compiled_regex(pattern: string, flags: uint8): Regex {.gcsafe.}
proc extract_regex(value: Value, pattern: var string, flags: var uint8) {.gcsafe.}
proc regex_match_bool(input: string, regex_val: Value): bool {.gcsafe.}
proc regex_process_match(input: string, regex_val: Value): Value {.gcsafe.}
proc regex_find_first(input: string, regex_val: Value): Value {.gcsafe.}
proc regex_find_all_values(input: string, regex_val: Value): Value {.gcsafe.}
proc regex_replace_value(input: string, regex_val: Value, replacement_override: Value, replace_all: bool): Value {.gcsafe.}
proc parse_json_string(json_str: string): Value {.gcsafe.}

proc init_string_class(object_class: Class) =
  var r: ptr Reference
  let string_class = new_class("String")
  string_class.parent = object_class
  string_class.def_native_method("to_s", object_to_s_method)

  # String constructor - concatenates all arguments into a string
  proc string_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    var buffer = newStringOfCap(32)
    for i in 0..<positional:
      let arg = get_positional_arg(args, i, has_keyword_args)
      buffer.add(display_value(arg, true))
    buffer.to_value()

  string_class.def_native_constructor(string_constructor)

  proc ensure_mutable_string(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], has_keyword_args: bool): Value =
    ## Return the string value (all strings are now mutable heap allocations)
    let self_index = if has_keyword_args: 1 else: 0
    let original = args[self_index]
    let raw = cast[uint64](original)
    let tag = raw and 0xFFFF_0000_0000_0000u64

    case tag
    of STRING_TAG:
      return original  # All strings use the same representation, no conversion needed
    else:
      return original

  # append method
  proc string_append(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("String.append requires a value to append")

    var self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("append must be called on a string")

    self_arg = ensure_mutable_string(vm, args, has_keyword_args)
    let ptr_addr = cast[uint64](self_arg) and PAYLOAD_MASK
    if ptr_addr == 0:
      not_allowed("append must be called on a string")
    let str_ref = cast[ptr String](ptr_addr)
    var i = 1
    while i < pos_count:
      let append_arg = get_positional_arg(args, i, has_keyword_args)
      let addition = if append_arg.kind == VkString:
        append_arg.str
      else:
        display_value(append_arg, true)
      str_ref.str.add(addition)
      i.inc()
    self_arg

  var append_fn = new_ref(VkNativeFn)
  append_fn.native_fn = string_append
  string_class.def_native_method("append", append_fn.native_fn)

  # length method
  proc string_length(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "String.length requires self argument")

    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      raise new_exception(types.Exception, "length can only be called on a string")

    return self_arg.str.len.int64.to_value()

  var length_fn = new_ref(VkNativeFn)
  length_fn.native_fn = string_length
  string_class.def_native_method("length", length_fn.native_fn)
  string_class.def_native_method("size", length_fn.native_fn)

  proc string_to_i(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.to_i requires self argument")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("to_i can only be called on a string")
    let trimmed = self_arg.str.strip()
    if trimmed.len == 0:
      not_allowed("to_i requires a numeric string")
    try:
      return trimmed.parseInt().int64.to_value()
    except ValueError:
      not_allowed("to_i requires a numeric string")

  string_class.def_native_method("to_i", string_to_i)

  # to_upper method
  proc string_to_upper(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "String.to_upper requires self argument")

    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      raise new_exception(types.Exception, "to_upper can only be called on a string")

    return self_arg.str.toUpperAscii().to_value()

  var to_upper_fn = new_ref(VkNativeFn)
  to_upper_fn.native_fn = string_to_upper
  string_class.def_native_method("to_upper", to_upper_fn.native_fn)

  # to_lower method
  proc string_to_lower(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "String.to_lower requires self argument")

    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      raise new_exception(types.Exception, "to_lower can only be called on a string")

    return self_arg.str.toLowerAscii().to_value()

  var to_lower_fn = new_ref(VkNativeFn)
  to_lower_fn.native_fn = string_to_lower
  string_class.def_native_method("to_lower", to_lower_fn.native_fn)
  string_class.def_native_method("to_lowercase", to_lower_fn.native_fn)

  proc string_to_uppercase(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    string_to_upper(vm, args, arg_count, has_keyword_args)

  proc string_to_lowercase(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    string_to_lower(vm, args, arg_count, has_keyword_args)

  string_class.def_native_method("to_uppercase", string_to_uppercase)
  string_class.def_native_method("to_lowercase", string_to_lowercase)

  proc string_substr(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.substr requires start index")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("substr must be called on a string")
    let s = self_arg.str
    let len = s.len
    if len == 0:
      return "".to_value()

    proc adjust(idx: int64; allowLen: bool): int =
      var res = int(idx)
      if res < 0:
        res = len + res
      if res < 0:
        res = 0
      if allowLen:
        if res > len:
          res = len
      else:
        if res >= len:
          res = len - 1
      res

    let start_idx64 = get_positional_arg(args, 1, has_keyword_args).to_int()
    var start_idx = adjust(start_idx64, true)
    if start_idx >= len:
      return "".to_value()

    if get_positional_count(arg_count, has_keyword_args) == 2:
      return s[start_idx..^1].to_value()

    let end_idx64 = get_positional_arg(args, 2, has_keyword_args).to_int()
    var end_idx = adjust(end_idx64, false)
    if end_idx < start_idx:
      return "".to_value()
    result = s[start_idx..end_idx].to_value()

  string_class.def_native_method("substr", string_substr)

  proc string_split(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.split requires separator")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("split must be called on a string")
    let sep_arg = get_positional_arg(args, 1, has_keyword_args)
    if sep_arg.kind != VkString:
      not_allowed("split separator must be a string")
    let sep = sep_arg.str
    var parts: seq[string]
    if get_positional_count(arg_count, has_keyword_args) >= 3:
      let limit = max(1, get_positional_arg(args, 2, has_keyword_args).to_int().int)
      parts = self_arg.str.split(sep, limit - 1)
    else:
      parts = self_arg.str.split(sep)
    var arr_ref = new_array_value()
    for part in parts:
      array_data(arr_ref).add(part.to_value())
    arr_ref

  string_class.def_native_method("split", string_split)

  proc string_index(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.index requires substring")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("index must be called on a string")
    let needle = get_positional_arg(args, 1, has_keyword_args)
    if needle.kind != VkString:
      not_allowed("index substring must be a string")
    let pos = self_arg.str.find(needle.str)
    pos.to_value()

  string_class.def_native_method("index", string_index)

  proc string_rindex(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.rindex requires substring")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("rindex must be called on a string")
    let needle = get_positional_arg(args, 1, has_keyword_args)
    if needle.kind != VkString:
      not_allowed("rindex substring must be a string")
    let pos = self_arg.str.rfind(needle.str)
    pos.to_value()

  string_class.def_native_method("rindex", string_rindex)

  proc string_trim(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.trim requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("trim must be called on a string")
    self_arg.str.strip().to_value()

  string_class.def_native_method("trim", string_trim)

  proc string_starts_with(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.starts_with requires prefix")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let prefix = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString or prefix.kind != VkString:
      not_allowed("starts_with expects string arguments")
    self_arg.str.startsWith(prefix.str).to_value()

  proc string_ends_with(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.ends_with requires suffix")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let suffix = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString or suffix.kind != VkString:
      not_allowed("ends_with expects string arguments")
    self_arg.str.endsWith(suffix.str).to_value()

  string_class.def_native_method("starts_with", string_starts_with)
  string_class.def_native_method("ends_with", string_ends_with)

  proc string_char_at(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.char_at requires index")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString or idx_val.kind != VkInt:
      not_allowed("char_at expects string and integer")
    let idx = idx_val.int64.int
    if idx < 0 or idx >= self_arg.str.len:
      not_allowed("char_at index out of bounds")
    self_arg.str[idx].to_value()

  string_class.def_native_method("char_at", string_char_at)

  proc string_match(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.match requires a Regexp")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("match must be called on a string")
    if pattern_val.kind != VkRegex:
      not_allowed("String.match requires a Regexp")
    regex_match_bool(self_arg.str, pattern_val).to_value()

  string_class.def_native_method("match", string_match)

  proc string_contain(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.contain requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("contain must be called on a string")
    case pattern_val.kind
    of VkRegex:
      result = regex_match_bool(self_arg.str, pattern_val).to_value()
    of VkString:
      result = (self_arg.str.find(pattern_val.str) >= 0).to_value()
    else:
      not_allowed("String.contain expects a Regexp or string pattern")

  string_class.def_native_method("contain", string_contain)

  proc string_find(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.find requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("find must be called on a string")
    case pattern_val.kind
    of VkRegex:
      result = regex_find_first(self_arg.str, pattern_val)
    of VkString:
      if pattern_val.str.len == 0:
        not_allowed("String.find pattern cannot be empty")
      let idx = self_arg.str.find(pattern_val.str)
      if idx < 0:
        result = NIL
      else:
        result = self_arg.str[idx ..< idx + pattern_val.str.len].to_value()
    else:
      not_allowed("String.find expects a Regexp or string pattern")

  string_class.def_native_method("find", string_find)

  proc string_find_all(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.find_all requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("find_all must be called on a string")
    case pattern_val.kind
    of VkRegex:
      result = regex_find_all_values(self_arg.str, pattern_val)
    of VkString:
      if pattern_val.str.len == 0:
        not_allowed("String.find_all pattern cannot be empty")
      var matches = new_array_value()
      var start = 0
      while start <= self_arg.str.len:
        let idx = self_arg.str.find(pattern_val.str, start)
        if idx < 0:
          break
        array_data(matches).add(self_arg.str[idx ..< idx + pattern_val.str.len].to_value())
        start = idx + pattern_val.str.len
      result = matches
    else:
      not_allowed("String.find_all expects a Regexp or string pattern")

  string_class.def_native_method("find_all", string_find_all)

  proc string_replace(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("String.replace requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("replace must be called on a string")
    case pattern_val.kind
    of VkRegex:
      let replacement_val = if pos_count >= 3: get_positional_arg(args, 2, has_keyword_args) else: NIL
      result = regex_replace_value(self_arg.str, pattern_val, replacement_val, false)
    of VkString:
      if pos_count < 3:
        not_allowed("String.replace requires target and replacement")
      let to_val = get_positional_arg(args, 2, has_keyword_args)
      if to_val.kind != VkString:
        not_allowed("replace expects string replacement")
      let idx = self_arg.str.find(pattern_val.str)
      if idx < 0:
        result = self_arg.str.to_value()
      else:
        let prefix = if idx > 0: self_arg.str[0 ..< idx] else: ""
        let start = idx + pattern_val.str.len
        let suffix = if start < self_arg.str.len: self_arg.str[start .. ^1] else: ""
        result = (prefix & to_val.str & suffix).to_value()
    else:
      not_allowed("String.replace expects a Regexp or string pattern")

  string_class.def_native_method("replace", string_replace)

  proc string_replace_all(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("String.replace_all requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("replace_all must be called on a string")
    case pattern_val.kind
    of VkRegex:
      let replacement_val = if pos_count >= 3: get_positional_arg(args, 2, has_keyword_args) else: NIL
      result = regex_replace_value(self_arg.str, pattern_val, replacement_val, true)
    of VkString:
      if pos_count < 3:
        not_allowed("String.replace_all requires target and replacement")
      let to_val = get_positional_arg(args, 2, has_keyword_args)
      if to_val.kind != VkString:
        not_allowed("replace_all expects string replacement")
      result = self_arg.str.replace(pattern_val.str, to_val.str).to_value()
    else:
      not_allowed("String.replace_all expects a Regexp or string pattern")

  string_class.def_native_method("replace_all", string_replace_all)

  proc gene_dollar(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    var buffer = newStringOfCap(16)
    for i in 0..<positional:
      let arg = get_positional_arg(args, i, has_keyword_args)
      buffer.add(display_value(arg, true))
    buffer.to_value()

  var dollar_fn = new_ref(VkNativeFn)
  dollar_fn.native_fn = gene_dollar
  App.app.gene_ns.ns["$".to_key()] = dollar_fn.to_ref_value()
  App.app.global_ns.ns["$".to_key()] = dollar_fn.to_ref_value()

  r = new_ref(VkClass)
  r.class = string_class
  App.app.string_class = r.to_ref_value()
  App.app.gene_ns.ns["String".to_key()] = App.app.string_class
  App.app.global_ns.ns["String".to_key()] = App.app.string_class

proc init_regex_class(object_class: Class) =
  var r: ptr Reference
  let regex_class = new_class("Regexp")
  regex_class.parent = object_class

  proc regexp_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 1:
      not_allowed("Regexp.ctor requires a pattern string")
    let pattern_val = get_positional_arg(args, 0, has_keyword_args)
    if pattern_val.kind != VkString:
      not_allowed("Regexp.ctor expects a string pattern")

    var replacement = ""
    var has_replacement = false
    if pos_count >= 2:
      let replacement_val = get_positional_arg(args, 1, has_keyword_args)
      if replacement_val != NIL and replacement_val.kind != VkString:
        not_allowed("Regexp.ctor replacement must be a string or nil")
      if replacement_val.kind == VkString:
        replacement = replacement_val.str
        has_replacement = true
    if pos_count > 2:
      not_allowed("Regexp.ctor accepts at most pattern and replacement")

    var ignore_case = false
    var multiline = false
    if has_keyword_args and args[0].kind == VkMap:
      for k, v in map_data(args[0]):
        let key_name = cast[Value](k).str
        case key_name
        of "i":
          ignore_case = v.to_bool()
        of "m":
          multiline = v.to_bool()
        else:
          not_allowed("Regexp.ctor unknown flag: " & key_name)

    let flags = build_regex_flags(ignore_case, multiline)
    new_regex_value(pattern_val.str, flags, replacement, has_replacement)

  regex_class.def_native_constructor(regexp_constructor)

  proc regexp_match(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Regexp.match requires an input string")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let input_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkRegex or input_val.kind != VkString:
      not_allowed("Regexp.match expects a Regexp and string")
    regex_match_bool(input_val.str, self_arg).to_value()

  proc regexp_process(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Regexp.process requires an input string")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let input_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkRegex or input_val.kind != VkString:
      not_allowed("Regexp.process expects a Regexp and string")
    regex_process_match(input_val.str, self_arg)

  proc regexp_find(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Regexp.find requires an input string")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let input_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkRegex or input_val.kind != VkString:
      not_allowed("Regexp.find expects a Regexp and string")
    regex_find_first(input_val.str, self_arg)

  proc regexp_find_all(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Regexp.find_all requires an input string")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let input_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkRegex or input_val.kind != VkString:
      not_allowed("Regexp.find_all expects a Regexp and string")
    regex_find_all_values(input_val.str, self_arg)

  proc regexp_replace(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Regexp.replace requires an input string")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let input_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkRegex or input_val.kind != VkString:
      not_allowed("Regexp.replace expects a Regexp and string")
    let replacement_val = if pos_count >= 3: get_positional_arg(args, 2, has_keyword_args) else: NIL
    regex_replace_value(input_val.str, self_arg, replacement_val, false)

  proc regexp_replace_all(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Regexp.replace_all requires an input string")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let input_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkRegex or input_val.kind != VkString:
      not_allowed("Regexp.replace_all expects a Regexp and string")
    let replacement_val = if pos_count >= 3: get_positional_arg(args, 2, has_keyword_args) else: NIL
    regex_replace_value(input_val.str, self_arg, replacement_val, true)

  regex_class.def_native_method("match", regexp_match)
  regex_class.def_native_method("process", regexp_process)
  regex_class.def_native_method("find", regexp_find)
  regex_class.def_native_method("find_all", regexp_find_all)
  regex_class.def_native_method("replace", regexp_replace)
  regex_class.def_native_method("replace_all", regexp_replace_all)

  r = new_ref(VkClass)
  r.class = regex_class
  App.app.regex_class = r.to_ref_value()
  App.app.gene_ns.ns["Regexp".to_key()] = App.app.regex_class
  App.app.global_ns.ns["Regexp".to_key()] = App.app.regex_class

proc init_symbol_classes(object_class: Class) =
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

proc init_collection_classes(object_class: Class) =
  var r: ptr Reference
  let array_class = new_class("Array")
  array_class.parent = object_class
  array_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = array_class
  App.app.array_class = r.to_ref_value()
  App.app.gene_ns.ns["Array".to_key()] = App.app.array_class
  App.app.global_ns.ns["Array".to_key()] = App.app.array_class

  proc vm_array_add(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    # First argument is the array (self), second is the value to add
    let arr = get_positional_arg(args, 0, has_keyword_args)
    let value = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: NIL
    if arr.kind == VkArray:
      array_data(arr).add(value)
    return arr

  array_class.def_native_method("add", vm_array_add)
  array_class.def_native_method("append", vm_array_add)  # Alias for add

  proc vm_array_size(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    # First argument is the array (self)
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind == VkArray:
      return array_data(arr).len.to_value()
    return 0.to_value()

  array_class.def_native_method("size", vm_array_size)
  array_class.def_native_method("length", vm_array_size)  # Alias for size

  proc vm_array_get(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    # First argument is the array (self), second is the index
    let arr = get_positional_arg(args, 0, has_keyword_args)
    let index = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: 0.to_value()
    if arr.kind == VkArray and index.kind == VkInt:
      let idx = index.int64.int
      if idx >= 0 and idx < array_data(arr).len:
        return array_data(arr)[idx]
    return NIL

  array_class.def_native_method("get", vm_array_get)

  proc normalize_index(len: int, raw: int64): int {.inline.} =
    var idx = raw.int
    if idx < 0:
      idx = len + idx
    idx

  proc vm_array_set(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Array.set requires index and value")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("set must be called on an array")
    let index_val = get_positional_arg(args, 1, has_keyword_args)
    if index_val.kind != VkInt:
      not_allowed("set index must be an integer")
    let len = array_data(arr).len
    var idx = normalize_index(len, index_val.int64)
    if idx < 0 or idx >= len:
      not_allowed("set index out of bounds")
    let value = get_positional_arg(args, 2, has_keyword_args)
    array_data(arr)[idx] = value
    arr

  array_class.def_native_method("set", vm_array_set)

  proc vm_array_del(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.del requires index")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("del must be called on an array")
    let index_val = get_positional_arg(args, 1, has_keyword_args)
    if index_val.kind != VkInt:
      not_allowed("del index must be an integer")
    var arr_data = array_data(arr)
    let len = arr_data.len
    var idx = normalize_index(len, index_val.int64)
    if idx < 0 or idx >= len:
      not_allowed("del index out of bounds")
    let removed = arr_data[idx]
    arr_data.delete(idx)
    removed

  array_class.def_native_method("del", vm_array_del)

  proc vm_array_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.empty requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("empty must be called on an array")
    (array_data(arr).len == 0).to_value()

  array_class.def_native_method("empty", vm_array_empty)

  proc vm_array_contains(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.contains requires value")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("contains must be called on an array")
    let needle = get_positional_arg(args, 1, has_keyword_args)
    for item in array_data(arr):
      if item == needle:
        return TRUE
    FALSE

  array_class.def_native_method("contains", vm_array_contains)

  proc vm_array_to_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.to_json requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("to_json must be called on an array")
    value_to_json(arr).to_value()

  array_class.def_native_method("to_json", vm_array_to_json)

  proc vm_array_each(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.each requires a function")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("each must be called on an array")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    case callback.kind
    of VkFunction:
      for item in array_data(arr):
        {.cast(gcsafe).}:
          discard vm_exec_callable(vm, callback, @[item])
    of VkNativeFn:
      for item in array_data(arr):
        {.cast(gcsafe).}:
          discard call_native_fn(callback.ref.native_fn, vm, [item])
    else:
      not_allowed("each callback must be a function")
    arr

  array_class.def_native_method("each", vm_array_each)

  proc vm_array_map(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.map requires a function")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("map must be called on an array")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    var mapped: seq[Value] = @[]
    case callback.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        var mapped_value: Value
        {.cast(gcsafe).}:
          mapped_value = vm_exec_callable(vm, callback, @[item])
        mapped.add(mapped_value)
    else:
      not_allowed("map callback must be a function, got " & $callback.kind)
    var result = new_array_value()
    array_data(result) = mapped
    result

  array_class.def_native_method("map", vm_array_map)

  proc vm_array_join(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 1:
      not_allowed("Array.join requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("join must be called on an array")
    let sep = if pos_count > 1:
      let sep_arg = get_positional_arg(args, 1, has_keyword_args)
      if sep_arg.kind != VkString:
        not_allowed("Array.join separator must be a string")
      sep_arg.str
    else:
      ""
    var parts: seq[string] = @[]
    for item in array_data(arr):
      parts.add(display_value(item, true))
    parts.join(sep).to_value()

  array_class.def_native_method("join", vm_array_join)

  let map_class = new_class("Map")
  map_class.parent = object_class
  map_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = map_class
  App.app.map_class = r.to_ref_value()
  App.app.gene_ns.ns["Map".to_key()] = App.app.map_class
  App.app.global_ns.ns["Map".to_key()] = App.app.map_class

  proc vm_map_contains(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    # First argument is the map (self), second is the key
    let map = get_positional_arg(args, 0, has_keyword_args)
    let key = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: NIL
    if map.kind == VkMap and key.kind == VkString:
      return map_data(map).hasKey(key.str.to_key()).to_value()
    elif map.kind == VkMap and key.kind == VkSymbol:
      return map_data(map).hasKey(key.str.to_key()).to_value()
    return false.to_value()

  proc vm_map_get(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    # map.get(key, default?) -> value|default|nil
    if arg_count < 2:
      not_allowed("Map.get expects at least a key argument")

    let map = get_positional_arg(args, 0, has_keyword_args)
    if map.kind != VkMap:
      not_allowed("Map.get must be called on a map")

    let keyVal = get_positional_arg(args, 1, has_keyword_args)
    var key: Key

    case keyVal.kind
    of VkString:
      key = keyVal.str.to_key()
    of VkSymbol:
      key = keyVal.str.to_key()
    else:
      not_allowed("Map.get key must be a string or symbol")

    if map_data(map).hasKey(key):
      return map_data(map)[key]

    if arg_count >= 3:
      return get_positional_arg(args, 2, has_keyword_args)

    return NIL

  map_class.def_native_method("get", vm_map_get)

  proc vm_map_set(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    # map.set(key, value) -> map (returns self for chaining)
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Map.set expects key and value arguments")

    let map = get_positional_arg(args, 0, has_keyword_args)
    if map.kind != VkMap:
      not_allowed("Map.set must be called on a map")

    let keyVal = get_positional_arg(args, 1, has_keyword_args)
    var key: Key

    case keyVal.kind
    of VkString:
      key = keyVal.str.to_key()
    of VkSymbol:
      key = keyVal.str.to_key()
    else:
      not_allowed("Map.set key must be a string or symbol")

    let value = get_positional_arg(args, 2, has_keyword_args)
    map_data(map)[key] = value
    return map

  map_class.def_native_method("set", vm_map_set)

  map_class.def_native_method("contains", vm_map_contains)

  proc vm_map_size(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.size requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("size must be called on a map")
    map_data(map_val).len.to_value()

  map_class.def_native_method("size", vm_map_size)

  proc vm_map_keys(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.keys requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("keys must be called on a map")
    var result_ref = new_array_value()
    for key, _ in map_data(map_val):
      let key_val = cast[Value](key)
      array_data(result_ref).add(key_val.str.to_value())
    result_ref

  map_class.def_native_method("keys", vm_map_keys)

  proc vm_map_values(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.values requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("values must be called on a map")
    var result_ref = new_array_value()
    for _, value in map_data(map_val):
      array_data(result_ref).add(value)
    result_ref

  map_class.def_native_method("values", vm_map_values)

  proc vm_map_map(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Map.map requires a function")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("map must be called on a map")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    var result_ref = new_array_value()
    case callback.kind
    of VkFunction:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          let mapped = vm_exec_callable(vm, callback, @[key_val, value])
          array_data(result_ref).add(mapped)
    of VkNativeFn:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          let mapped = call_native_fn(callback.ref.native_fn, vm, [key_val, value])
          array_data(result_ref).add(mapped)
    else:
      not_allowed("map callback must be a function")
    result_ref

  map_class.def_native_method("map", vm_map_map)

  proc vm_map_each(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Map.each requires a function")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("each must be called on a map")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    case callback.kind
    of VkFunction:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          discard vm_exec_callable(vm, callback, @[key_val.str.to_value(), value])
    of VkNativeFn:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          discard call_native_fn(callback.ref.native_fn, vm, [key_val.str.to_value(), value])
    else:
      not_allowed("each callback must be a function")
    map_val

  map_class.def_native_method("each", vm_map_each)

  proc vm_map_to_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.to_json requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("to_json must be called on a map")
    value_to_json(map_val).to_value()

  map_class.def_native_method("to_json", vm_map_to_json)

proc init_date_classes(object_class: Class) =
  var r: ptr Reference
  let date_class = new_class("Date")
  date_class.parent = object_class
  date_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = date_class
  App.app.date_class = r.to_ref_value()
  App.app.gene_ns.ns["Date".to_key()] = App.app.date_class
  App.app.global_ns.ns["Date".to_key()] = App.app.date_class

  proc date_year(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Date.year requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDate:
      not_allowed("Date.year must be called on a date")
    self_val.ref.date_year.int.to_value()

  proc date_month(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Date.month requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDate:
      not_allowed("Date.month must be called on a date")
    self_val.ref.date_month.int.to_value()

  proc date_day(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Date.day requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDate:
      not_allowed("Date.day must be called on a date")
    self_val.ref.date_day.int.to_value()

  date_class.def_native_method("year", date_year)
  date_class.def_native_method("month", date_month)
  date_class.def_native_method("day", date_day)

  let datetime_class = new_class("DateTime")
  datetime_class.parent = object_class
  datetime_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = datetime_class
  App.app.datetime_class = r.to_ref_value()
  App.app.gene_ns.ns["DateTime".to_key()] = App.app.datetime_class
  App.app.global_ns.ns["DateTime".to_key()] = App.app.datetime_class

  proc datetime_year(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.year requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.year must be called on a datetime")
    self_val.ref.dt_year.int.to_value()

  proc datetime_month(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.month requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.month must be called on a datetime")
    self_val.ref.dt_month.int.to_value()

  proc datetime_day(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.day requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.day must be called on a datetime")
    self_val.ref.dt_day.int.to_value()

  proc datetime_hour(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("DateTime.hour requires self")
    let self_val = get_positional_arg(args, 0, has_keyword_args)
    if self_val.kind != VkDateTime:
      not_allowed("DateTime.hour must be called on a datetime")
    self_val.ref.dt_hour.int.to_value()

  datetime_class.def_native_method("year", datetime_year)
  datetime_class.def_native_method("month", datetime_month)
  datetime_class.def_native_method("day", datetime_day)
  datetime_class.def_native_method("hour", datetime_hour)

proc init_regex_and_json() =
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

proc init_date_functions() =
  proc gene_today_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = times.now()
    new_date_value(dt.year, ord(dt.month), dt.monthday)

  proc gene_now_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = times.now()
    new_datetime_value(dt)

  proc gene_yesterday_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = times.now() - initDuration(days = 1)
    new_date_value(dt.year, ord(dt.month), dt.monthday)

  proc gene_tomorrow_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let dt = times.now() + initDuration(days = 1)
    new_date_value(dt.year, ord(dt.month), dt.monthday)

  var today_fn = new_ref(VkNativeFn)
  today_fn.native_fn = gene_today_native
  App.app.gene_ns.ns["today".to_key()] = today_fn.to_ref_value()

  var now_fn = new_ref(VkNativeFn)
  now_fn.native_fn = gene_now_native
  App.app.gene_ns.ns["now".to_key()] = now_fn.to_ref_value()

  var yesterday_fn = new_ref(VkNativeFn)
  yesterday_fn.native_fn = gene_yesterday_native
  App.app.gene_ns.ns["yesterday".to_key()] = yesterday_fn.to_ref_value()

  var tomorrow_fn = new_ref(VkNativeFn)
  tomorrow_fn.native_fn = gene_tomorrow_native
  App.app.gene_ns.ns["tomorrow".to_key()] = tomorrow_fn.to_ref_value()

proc init_selector_class(object_class: Class) =
  var r: ptr Reference
  let selector_class = new_class("Selector")
  selector_class.parent = object_class
  selector_class.def_native_method("to_s", object_to_s_method)

  proc selector_call(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if arg_count < 2:
      not_allowed("Selector.call expects a target value")

    let selector_val = get_positional_arg(args, 0, has_keyword_args)
    if selector_val.kind != VkSelector:
      not_allowed("Selector.call must be invoked on a selector")

    let target = get_positional_arg(args, 1, has_keyword_args)
    let has_default = arg_count >= 3
    let default_value = if has_default: get_positional_arg(args, 2, has_keyword_args) else: NIL

    type SelectorMode = enum
      SmValue
      SmValues
      SmEntries

    var mode = SmValue
    var current = target
    var values_stream: seq[Value] = @[]
    var entries_stream: seq[(Key, Value)] = @[]

    proc is_selector_callable(seg: Value): bool {.inline.} =
      seg.kind in {VkFunction, VkNativeFn, VkBlock, VkBoundMethod, VkNativeMethod}

    proc key_to_symbol_value(k: Key): Value {.inline.} =
      cast[Value](k)

    proc collect_values(values: seq[Value]): Value =
      var r = new_array_value()
      for v in values:
        array_data(r).add(v)
      r

    proc collect_pairs(entries: seq[(Key, Value)]): Value =
      var r = new_array_value()
      for (k, v) in entries:
        var pair = new_array_value()
        array_data(pair).add(key_to_symbol_value(k))
        array_data(pair).add(v)
        array_data(r).add(pair)
      r

    proc collect_entries_to_map(entries: seq[(Key, Value)]): Value =
      var r = new_map_value()
      for (k, v) in entries:
        if v != VOID:
          map_data(r)[k] = v
      r

    proc expand_values(v: Value): seq[Value] =
      if v == VOID or v == NIL:
        return @[]
      case v.kind:
      of VkArray:
        result = @[]
        for item in array_data(v):
          if item != VOID:
            result.add(item)
      of VkGene:
        result = @[]
        for child in v.gene.children:
          if child != VOID:
            result.add(child)
      else:
        result = @[]

    proc expand_entries(v: Value): seq[(Key, Value)] =
      if v == VOID or v == NIL:
        return @[]
      result = @[]
      case v.kind:
      of VkMap:
        for k, item in map_data(v):
          if item != VOID:
            result.add((k, item))
      of VkGene:
        for k, item in v.gene.props:
          if item != VOID:
            result.add((k, item))
      of VkNamespace:
        for k, item in v.ref.ns.members:
          if item != VOID:
            result.add((k, item))
      of VkClass:
        for k, item in v.ref.class.ns.members:
          if item != VOID:
            result.add((k, item))
      of VkInstance:
        for k, item in instance_props(v):
          if item != VOID:
            result.add((k, item))
      else:
        discard

    proc apply_lookup(base: Value, seg: Value): Value =
      if base == VOID or base == NIL:
        return VOID

      case seg.kind:
      of VkString, VkSymbol:
        let key = seg.str.to_key()
        case base.kind:
        of VkMap:
          return map_data(base).getOrDefault(key, VOID)
        of VkGene:
          if key in base.gene.props:
            return base.gene.props[key]
          return VOID
        of VkNamespace:
          if base.ref.ns.has_key(key):
            return base.ref.ns[key]
          return VOID
        of VkClass:
          if base.ref.class.ns.has_key(key):
            return base.ref.class.ns[key]
          return VOID
        of VkInstance:
          return instance_props(base).getOrDefault(key, VOID)
        else:
          return VOID
      of VkInt:
        let idx64 = seg.int64
        case base.kind:
        of VkArray:
          let arr_len = array_data(base).len.int64
          var resolved = idx64
          if resolved < 0:
            resolved = arr_len + resolved
          if resolved >= 0 and resolved < arr_len:
            return array_data(base)[resolved.int]
          return VOID
        of VkGene:
          let children_len = base.gene.children.len.int64
          var resolved = idx64
          if resolved < 0:
            resolved = children_len + resolved
          if resolved >= 0 and resolved < children_len:
            return base.gene.children[resolved.int]
          return VOID
        else:
          return VOID
      else:
        not_allowed("Invalid selector segment type: " & $seg.kind)
        return VOID

    proc parse_pair_value(pair_val: Value): (Key, Value) =
      if pair_val.kind != VkArray:
        not_allowed("Entry transform must return [key value], got " & $pair_val.kind)
      let items = array_data(pair_val)
      if items.len != 2:
        not_allowed("Entry transform must return [key value]")
      let key_val = items[0]
      let key = case key_val.kind:
        of VkString, VkSymbol: key_val.str.to_key()
        of VkInt: ($key_val.int64).to_key()
        else:
          not_allowed("Entry key must be string/symbol/int, got " & $key_val.kind)
          "".to_key()
      (key, items[1])

    for seg in selector_val.ref.selector_path:
      # /! strictness
      if seg.kind == VkSymbol and seg.str == "!":
        case mode:
        of SmValue:
          if current == VOID:
            not_allowed("Selector did not match (VOID)")
        of SmValues:
          if values_stream.len == 0:
            not_allowed("Selector did not match (empty)")
          for v in values_stream:
            if v == VOID:
              not_allowed("Selector did not match (VOID)")
        of SmEntries:
          if entries_stream.len == 0:
            not_allowed("Selector did not match (empty)")
          for (_, v) in entries_stream:
            if v == VOID:
              not_allowed("Selector did not match (VOID)")
        continue

      # Token operators: *, **, @, @@
      if seg.kind == VkSymbol:
        case seg.str:
        of "*":
          case mode:
          of SmValue:
            values_stream = expand_values(current)
          of SmValues:
            var next: seq[Value] = @[]
            for v in values_stream:
              for item in expand_values(v):
                next.add(item)
            values_stream = next
          of SmEntries:
            var next: seq[Value] = @[]
            for (_, v) in entries_stream:
              for item in expand_values(v):
                next.add(item)
            values_stream = next
          entries_stream = @[]
          current = VOID
          mode = SmValues
          continue
        of "**":
          case mode:
          of SmValue:
            entries_stream = expand_entries(current)
          of SmValues:
            var next: seq[(Key, Value)] = @[]
            for v in values_stream:
              for item in expand_entries(v):
                next.add(item)
            entries_stream = next
          of SmEntries:
            var next: seq[(Key, Value)] = @[]
            for (_, v) in entries_stream:
              for item in expand_entries(v):
                next.add(item)
            entries_stream = next
          values_stream = @[]
          current = VOID
          mode = SmEntries
          continue
        of "@":
          case mode:
          of SmValue:
            if current == VOID:
              current = new_array_value()
            else:
              current = collect_values(@[current])
          of SmValues:
            current = collect_values(values_stream)
          of SmEntries:
            current = collect_pairs(entries_stream)
          values_stream = @[]
          entries_stream = @[]
          mode = SmValue
          continue
        of "@@":
          if mode != SmEntries:
            not_allowed("@@ requires an entry stream (use ** to expand entries first)")
          current = collect_entries_to_map(entries_stream)
          values_stream = @[]
          entries_stream = @[]
          mode = SmValue
          continue
        else:
          discard

      # Callable segments
      if is_selector_callable(seg):
        case mode:
        of SmValue:
          if current == VOID:
            discard
          else:
            var updated: Value = NIL
            {.cast(gcsafe).}:
              updated = vm_exec_callable(vm, seg, @[current])
            current = updated
        of SmValues:
          var next: seq[Value] = @[]
          for v in values_stream:
            var updated: Value = NIL
            {.cast(gcsafe).}:
              updated = vm_exec_callable(vm, seg, @[v])
            if updated != VOID:
              next.add(updated)
          values_stream = next
        of SmEntries:
          var next: seq[(Key, Value)] = @[]
          for (k, v) in entries_stream:
            var updated: Value = NIL
            {.cast(gcsafe).}:
              updated = vm_exec_callable(vm, seg, @[key_to_symbol_value(k), v])
            if updated == VOID:
              continue
            if updated.kind == VkArray:
              let (new_k, new_v) = parse_pair_value(updated)
              if new_v != VOID:
                next.add((new_k, new_v))
            else:
              if updated != VOID:
                next.add((k, updated))
          entries_stream = next
        continue

      # Normal lookup segments
      case mode:
      of SmValue:
        current = apply_lookup(current, seg)
      of SmValues:
        var next: seq[Value] = @[]
        for v in values_stream:
          let r = apply_lookup(v, seg)
          if r != VOID:
            next.add(r)
        values_stream = next
      of SmEntries:
        var next: seq[(Key, Value)] = @[]
        for (k, v) in entries_stream:
          let r = apply_lookup(v, seg)
          if r != VOID:
            next.add((k, r))
        entries_stream = next

    # Default trailing reduction for stream modes.
    case mode:
    of SmValue:
      if current == VOID and has_default:
        return default_value
      return current
    of SmValues:
      if values_stream.len == 0 and has_default:
        return default_value
      return collect_values(values_stream)
    of SmEntries:
      if entries_stream.len == 0 and has_default:
        return default_value
      return collect_pairs(entries_stream)

  selector_class.def_native_method("call", selector_call)

  r = new_ref(VkClass)
  r.class = selector_class
  App.app.selector_class = r.to_ref_value()
  if App.app.gene_ns.kind == VkNamespace:
    App.app.gene_ns.ref.ns["Selector".to_key()] = App.app.selector_class

proc init_set_class(object_class: Class) =
  var r: ptr Reference
  let set_class = new_class("Set")
  set_class.parent = object_class
  set_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = set_class
  App.app.set_class = r.to_ref_value()
  App.app.gene_ns.ns["Set".to_key()] = App.app.set_class
  App.app.global_ns.ns["Set".to_key()] = App.app.set_class

proc init_gene_and_meta_classes(object_class: Class) =
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

  let package_class = new_class("Package")
  package_class.parent = object_class
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
# Core functions for the Gene standard library

# Print without newline
proc core_print*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var s = ""
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let k = get_positional_arg(args, i, has_keyword_args)
    s &= k.str_no_quotes()
    if i < get_positional_count(arg_count, has_keyword_args) - 1:
      s &= " "
  stdout.write(s)
  return NIL

# Print with newline
proc core_println*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var s = ""
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let k = get_positional_arg(args, i, has_keyword_args)
    s &= k.str_no_quotes()
    if i < get_positional_count(arg_count, has_keyword_args) - 1:
      s &= " "
  echo s
  return NIL

# Assert condition
proc core_assert*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count > 0:
    let condition = get_positional_arg(args, 0, has_keyword_args)
    if not condition.to_bool():
      var msg = "Assertion failed"
      if arg_count > 1:
        msg = get_positional_arg(args, 1, has_keyword_args).str
      raise new_exception(types.Exception, msg)
  return NIL

proc contract_arg_snapshot(vm: ptr VirtualMachine): string =
  if vm == nil or vm.frame == nil or vm.frame.target.kind != VkFunction:
    return "[]"
  let f = vm.frame.target.ref.fn
  if f == nil or f.matcher == nil:
    return "[]"

  var parts: seq[string] = @[]
  for i, param in f.matcher.children:
    let arg_name = get_symbol_gcsafe(param.name_key.symbol_index)
    var arg_value = NIL
    var found = false
    if vm.frame.scope != nil and i < vm.frame.scope.members.len:
      arg_value = vm.frame.scope.members[i]
      found = true
    elif vm.frame.args.kind == VkGene and i < vm.frame.args.gene.children.len:
      arg_value = vm.frame.args.gene.children[i]
      found = true
    let rendered = if found: display_value(arg_value, false) else: "<missing>"
    parts.add(arg_name & "=" & rendered)
  "[" & parts.join(", ") & "]"

proc core_contracts_enabled(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                            arg_count: int, has_keyword_args: bool): Value =
  if vm != nil and vm.contracts_enabled:
    return TRUE
  FALSE

proc core_contract_violation(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                             arg_count: int, has_keyword_args: bool): Value =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional < 4:
    raise new_exception(types.Exception, "ContractViolation: internal contract metadata is incomplete")

  let phase_value = get_positional_arg(args, 0, has_keyword_args)
  let fn_value = get_positional_arg(args, 1, has_keyword_args)
  let index_value = get_positional_arg(args, 2, has_keyword_args)
  let condition_value = get_positional_arg(args, 3, has_keyword_args)

  let phase = display_value(phase_value, true)
  let function_name = display_value(fn_value, true)
  let condition_index =
    if index_value.kind == VkInt: to_int(index_value)
    else: 0'i64
  let condition_text =
    if condition_value.kind == VkString: condition_value.str
    else: display_value(condition_value, false)

  var message = "ContractViolation: " & function_name & " " & phase &
    "condition #" & $condition_index & " failed: " & condition_text
  message &= " | args=" & contract_arg_snapshot(vm)

  if phase == "post" and positional > 4:
    let result_value = get_positional_arg(args, 4, has_keyword_args)
    message &= " | result=" & display_value(result_value, false)

  raise new_exception(types.Exception, message)

# Get length of collection
proc core_len_impl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  let pos_count = get_positional_count(arg_count, has_keyword_args)
  if pos_count < 1:
    raise new_exception(types.Exception, "len requires 1 argument (collection)")

  let value = get_positional_arg(args, 0, has_keyword_args)
  result = value.size().int64.to_value()

proc core_len(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    return core_len_impl(vm, args, arg_count, has_keyword_args)

proc runtime_type_descs_for(vm: ptr VirtualMachine): seq[TypeDesc] =
  if vm != nil and vm.cu != nil and vm.cu.type_descriptors.len > 0:
    return vm.cu.type_descriptors
  return builtin_type_descs()

proc normalize_type_input(value: Value): Value =
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

proc core_types_equivalent(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                           has_keyword_args: bool): Value =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional < 2:
    raise new_exception(types.Exception, "types_equivalent requires 2 arguments")

  let left_raw = get_positional_arg(args, 0, has_keyword_args)
  let right_raw = get_positional_arg(args, 1, has_keyword_args)

  if left_raw.kind notin {VkSymbol, VkString, VkGene, VkClass, VkComplexSymbol}:
    not_allowed("types_equivalent expects a type expression/value as first argument")
  if right_raw.kind notin {VkSymbol, VkString, VkGene, VkClass, VkComplexSymbol}:
    not_allowed("types_equivalent expects a type expression/value as second argument")

  var descs = runtime_type_descs_for(vm)
  let left_id = resolve_type_value_to_id(normalize_type_input(left_raw), descs)
  let right_id = resolve_type_value_to_id(normalize_type_input(right_raw), descs)
  return types_equivalent(left_id, right_id, descs).to_value()

# Debug value (write to stderr)
proc core_debug*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let val = get_positional_arg(args, i, has_keyword_args)
    stderr.writeLine("<debug>: " & $val)
  return NIL

# Trace control
proc core_trace_start*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  vm.trace = true
  return NIL

proc core_trace_end*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  vm.trace = false
  return NIL

# Sleep (synchronous)
proc core_sleep*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "sleep requires 1 argument (duration in milliseconds)")

  let duration_arg = get_positional_arg(args, 0, has_keyword_args)
  var duration_ms: int

  case duration_arg.kind:
    of VkInt:
      duration_ms = duration_arg.int64.int
    of VkFloat:
      duration_ms = (duration_arg.float64 * 1000).int
    else:
      raise new_exception(types.Exception, "sleep requires a number (milliseconds)")

  sleep(duration_ms)
  return NIL

# Helper proc to call scheduler callbacks - isolates gcsafe access
proc call_scheduler_callbacks(vm: ptr VirtualMachine) {.gcsafe.} =
  {.cast(gcsafe).}:
    for callback in scheduler_callbacks:
      try:
        callback(vm)
      except CatchableError as e:
        when not defined(release):
          stderr.writeLine("Scheduler callback error: " & e.msg)

# Helper to check scheduler_callbacks length
proc scheduler_callbacks_len(): int {.gcsafe.} =
  {.cast(gcsafe).}:
    return scheduler_callbacks.len

# Helper to call poll_event_loop without gcsafe inference issue
proc do_poll_event_loop(vm: ptr VirtualMachine) {.gcsafe.} =
  {.cast(gcsafe).}:
    vm_poll_event_loop(vm)

# Run Nim's async event loop forever (scheduler mode)  
proc core_run_forever*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  ## Run the scheduler loop indefinitely until stop_scheduler is called.
  ## This polls Nim async events and calls registered extension callbacks.
  ## Uses idle backoff to reduce CPU usage when no pending work.
  
  # Enable polling and scheduler
  vm.poll_enabled = true
  vm.event_loop_counter = 0
  vm.scheduler_running = true
  
  # Idle backoff: increase poll timeout when no pending work
  var idle_count = 0
  const MAX_IDLE_BACKOFF = 32  # Max 32ms between polls when idle

  while vm.scheduler_running:
    # Check if there's pending work
    let has_pending_work = vm.pending_futures.len > 0 or
                           vm.thread_futures.len > 0 or
                           scheduler_callbacks_len() > 0

    # Calculate poll timeout with backoff
    let poll_timeout = if has_pending_work:
      idle_count = 0
      1  # 1ms when busy
    else:
      idle_count = min(idle_count + 1, MAX_IDLE_BACKOFF)
      idle_count  # Gradually increase timeout when idle

    # Process Nim's async events
    try:
      poll(poll_timeout)
    except:
      discard  # Ignore "No handles" exceptions
    
    # Poll Gene futures and execute callbacks inline
    do_poll_event_loop(vm)
    
    # Call all registered scheduler callbacks (extensions like HTTP register here)
    call_scheduler_callbacks(vm)
  
  vm.scheduler_running = false
  return NIL

# Stop the scheduler loop
proc core_stop_scheduler*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  ## Stop the scheduler loop. The run_forever call will return.
  vm.scheduler_running = false
  return NIL

proc core_repl(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  let parent_scope = if vm.frame != nil: vm.frame.scope else: nil
  let parent_tracker = if parent_scope != nil: parent_scope.tracker else: nil

  let scope_tracker = new_scope_tracker(parent_tracker)
  let scope = new_scope(scope_tracker, parent_scope)
  let ns = if vm.frame != nil and vm.frame.ns != nil:
    vm.frame.ns
  else:
    new_namespace(App.app.global_ns.ref.ns, "repl")

  let saved_frame = vm.frame
  let saved_cu = vm.cu
  let saved_pc = vm.pc
  let saved_exception = vm.current_exception
  let saved_repl_exception = vm.repl_exception

  if saved_exception != NIL:
    vm.repl_exception = saved_exception
    vm.current_exception = NIL

  let result = ({.cast(gcsafe).}:
    run_repl_session(vm, scope_tracker, scope, ns, "<repl>", "gene> ", true,
                     saved_frame, saved_cu, saved_pc)
  )
  vm.current_exception = saved_exception
  vm.repl_exception = saved_repl_exception
  scope.free()
  return result

# Environment variable functions
proc core_get_env*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "get_env requires at least 1 argument (variable name)")

  let name_arg = get_positional_arg(args, 0, has_keyword_args)
  if name_arg.kind != VkString:
    raise new_exception(types.Exception, "get_env requires a string variable name")

  let name = name_arg.str
  let value = getEnv(name, "")

  if value == "":
    # Check if default provided
    if arg_count > 1:
      return get_positional_arg(args, 1, has_keyword_args)
    else:
      return NIL
  else:
    return value.to_value()

proc core_set_env*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "set_env requires 2 arguments (name, value)")

  let name_arg = get_positional_arg(args, 0, has_keyword_args)
  let value_arg = get_positional_arg(args, 1, has_keyword_args)

  if name_arg.kind != VkString:
    raise new_exception(types.Exception, "set_env requires a string variable name")

  let name = name_arg.str
  let value = value_arg.str_no_quotes()

  putEnv(name, value)
  return NIL

proc core_has_env*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "has_env requires 1 argument (variable name)")

  let name_arg = get_positional_arg(args, 0, has_keyword_args)
  if name_arg.kind != VkString:
    raise new_exception(types.Exception, "has_env requires a string variable name")

  let name = name_arg.str
  return existsEnv(name).to_value()

# Base64 encoding/decoding
proc core_base64*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "base64 requires a string argument")

  let input = get_positional_arg(args, 0, has_keyword_args)
  if input.kind != VkString:
    raise new_exception(types.Exception, "base64 requires a string argument")

  let encoded = base64.encode(input.str)
  return encoded.to_value()

proc core_base64_decode*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "base64_decode requires a string argument")

  let input = get_positional_arg(args, 0, has_keyword_args)
  if input.kind != VkString:
    raise new_exception(types.Exception, "base64_decode requires a string argument")

  try:
    let decoded = base64.decode(input.str)
    return decoded.to_value()
  except ValueError as e:
    raise new_exception(types.Exception, "Invalid base64 string: " & e.msg)

# VM debugging functions
proc core_vm_print_stack*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var s = "Stack: "
  for i, reg in vm.frame.stack:
    if i > 0:
      s &= ", "
    if i == vm.frame.stack_index.int:
      s &= "=> "
    s &= $vm.frame.stack[i]
  echo s
  return NIL

proc core_vm_print_instructions*(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  echo vm.cu
  return NIL

type RegexCacheKey = tuple[pattern: string, flags: uint8]

var regex_cache {.threadvar.}: Table[RegexCacheKey, Regex]
var regex_cache_initialized {.threadvar.}: bool

proc build_regex_flags(ignore_case: bool, multiline: bool): uint8 {.inline, gcsafe.} =
  result = 0
  if ignore_case:
    result = result or REGEX_FLAG_IGNORE_CASE
  if multiline:
    result = result or REGEX_FLAG_MULTILINE

proc get_compiled_regex(pattern: string, flags: uint8): Regex {.gcsafe.} =
  if not regex_cache_initialized:
    regex_cache = init_table[RegexCacheKey, Regex]()
    regex_cache_initialized = true
  let key = (pattern, flags)
  if not regex_cache.hasKey(key):
    var opts: set[RegexFlag] = {}
    if (flags and REGEX_FLAG_IGNORE_CASE) != 0:
      opts.incl(reIgnoreCase)
    if (flags and REGEX_FLAG_MULTILINE) != 0:
      opts.incl(reDotAll)
    regex_cache[key] = re(pattern, opts)
  regex_cache[key]

proc extract_regex(value: Value, pattern: var string, flags: var uint8) {.gcsafe.} =
  case value.kind
  of VkRegex:
    pattern = value.ref.regex_pattern
    flags = value.ref.regex_flags
  of VkString:
    pattern = value.str
    flags = 0
  else:
    not_allowed("Expected a regex or string pattern")

proc count_regex_captures(pattern: string): int {.gcsafe.} =
  var count = 0
  var escaped = false
  var in_class = false
  var i = 0
  while i < pattern.len:
    let ch = pattern[i]
    if escaped:
      escaped = false
      inc i
      continue
    if ch == '\\':
      escaped = true
      inc i
      continue
    if in_class:
      if ch == ']':
        in_class = false
      inc i
      continue
    if ch == '[':
      in_class = true
      inc i
      continue
    if ch == '(':
      if i + 1 < pattern.len and pattern[i + 1] == '?':
        if i + 2 < pattern.len and pattern[i + 2] == '<':
          count.inc()
        elif i + 3 < pattern.len and pattern[i + 2] == 'P' and pattern[i + 3] == '<':
          count.inc()
      else:
        count.inc()
    inc i
  if count > MaxSubpatterns:
    result = MaxSubpatterns
  else:
    result = count

proc apply_regex_replacement(replacement_str: string, captures: seq[string], full_match: string): string {.gcsafe.} =
  result = ""
  var i = 0
  while i < replacement_str.len:
    if replacement_str[i] == '\\' and i + 1 < replacement_str.len:
      let next = replacement_str[i + 1]
      if next == '\\':
        result.add('\\')
        i += 2
        continue
      if next in {'0'..'9'}:
        var j = i + 1
        var num = 0
        while j < replacement_str.len and replacement_str[j] in {'0'..'9'}:
          num = num * 10 + (ord(replacement_str[j]) - ord('0'))
          j.inc()
        if num == 0:
          result.add(full_match)
        elif num - 1 < captures.len:
          result.add(captures[num - 1])
        i = j
        continue
      result.add('\\')
      i.inc()
      continue
    result.add(replacement_str[i])
    i.inc()

proc regex_match_bool(input: string, regex_val: Value): bool {.gcsafe.} =
  if regex_val.kind != VkRegex:
    not_allowed("Expected a Regexp")
  let regex_obj = get_compiled_regex(regex_val.ref.regex_pattern, regex_val.ref.regex_flags)
  return re.find(input, regex_obj) >= 0

proc regex_process_match(input: string, regex_val: Value): Value {.gcsafe.} =
  if regex_val.kind != VkRegex:
    not_allowed("Expected a Regexp")
  let pattern = regex_val.ref.regex_pattern
  let flags = regex_val.ref.regex_flags
  let regex_obj = get_compiled_regex(pattern, flags)
  let capture_count = count_regex_captures(pattern)
  var captures = newSeq[string](capture_count)
  let (first, last) = re.findBounds(input, regex_obj, captures)
  if first < 0:
    return NIL
  let end_pos = if last >= first: last + 1 else: first
  let match_val = if last >= first: input[first .. last] else: ""
  new_regex_match_value(match_val, captures, first.int64, end_pos.int64)

proc regex_find_first(input: string, regex_val: Value): Value {.gcsafe.} =
  if regex_val.kind != VkRegex:
    not_allowed("Expected a Regexp")
  let pattern = regex_val.ref.regex_pattern
  let flags = regex_val.ref.regex_flags
  let regex_obj = get_compiled_regex(pattern, flags)
  let capture_count = count_regex_captures(pattern)
  var captures = newSeq[string](capture_count)
  let (first, last) = re.findBounds(input, regex_obj, captures)
  if first < 0:
    return NIL
  if last < first:
    return "".to_value()
  input[first .. last].to_value()

proc regex_find_all_values(input: string, regex_val: Value): Value {.gcsafe.} =
  if regex_val.kind != VkRegex:
    not_allowed("Expected a Regexp")
  let pattern = regex_val.ref.regex_pattern
  let flags = regex_val.ref.regex_flags
  let regex_obj = get_compiled_regex(pattern, flags)
  var matches = new_array_value()
  for match in re.findAll(input, regex_obj):
    array_data(matches).add(match.to_value())
  matches

proc regex_replacement_from_args(regex_val: Value, replacement_override: Value): string {.gcsafe.} =
  if replacement_override.kind == VkString:
    return replacement_override.str
  if replacement_override != NIL and replacement_override != VOID:
    not_allowed("Replacement must be a string")
  if regex_val.ref.regex_has_replacement:
    return regex_val.ref.regex_replacement
  not_allowed("Replacement string is required")
  ""

proc regex_replace_internal(input: string, regex_obj: Regex, replacement: string, capture_count: int, replace_all: bool): string =
  var result_str = ""
  var search_pos = 0
  var captures = newSeq[string](capture_count)
  while search_pos <= input.len:
    if captures.len > 0:
      for i in 0..<captures.len:
        captures[i] = ""
    let (first, last) = re.findBounds(input, regex_obj, captures, search_pos)
    if first < 0:
      break
    if first > search_pos:
      result_str.add(input[search_pos ..< first])
    let match_val = if last >= first: input[first .. last] else: ""
    result_str.add(apply_regex_replacement(replacement, captures, match_val))
    let next_pos = if last >= first: last + 1 else: first
    if not replace_all:
      if next_pos < input.len:
        result_str.add(input[next_pos .. ^1])
      return result_str
    if next_pos == search_pos:
      search_pos = next_pos + 1
    else:
      search_pos = next_pos
  if search_pos < input.len:
    result_str.add(input[search_pos .. ^1])
  result_str

proc regex_replace_value(input: string, regex_val: Value, replacement_override: Value, replace_all: bool): Value {.gcsafe.} =
  if regex_val.kind != VkRegex:
    not_allowed("Expected a Regexp")
  let pattern = regex_val.ref.regex_pattern
  let flags = regex_val.ref.regex_flags
  let replacement = regex_replacement_from_args(regex_val, replacement_override)
  let regex_obj = get_compiled_regex(pattern, flags)
  let capture_count = count_regex_captures(pattern)
  regex_replace_internal(input, regex_obj, replacement, capture_count, replace_all).to_value()

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

proc parse_json_string(json_str: string): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    let parsed = nim_json.parseJson(json_str)
    return parse_json_node(parsed)

proc value_to_json(val: Value): string {.gcsafe.} =
  # Note: json.escapeJson already adds surrounding quotes
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

# Show the code
# JIT the code (create a temporary block, reuse the frame)
# Execute the code
# Show the result
proc debug(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  todo()

proc println(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var s = ""
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let k = get_positional_arg(args, i, has_keyword_args)
    s &= k.str_no_quotes()
    if i < get_positional_count(arg_count, has_keyword_args) - 1:
      s &= " "
  echo s
  return NIL

proc print(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var s = ""
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let k = get_positional_arg(args, i, has_keyword_args)
    s &= k.str_no_quotes()
    if i < get_positional_count(arg_count, has_keyword_args) - 1:
      s &= " "
  stdout.write(s)
  return NIL

proc gene_assert(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count > 0:
    let condition = get_positional_arg(args, 0, has_keyword_args)
    if not condition.to_bool():
      var msg = "Assertion failed"
      if arg_count > 1:
        msg = get_positional_arg(args, 1, has_keyword_args).str
      raise new_exception(types.Exception, msg)
  return NIL

proc base64_encode(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "base64_encode requires a string argument")

  let input = get_positional_arg(args, 0, has_keyword_args)
  if input.kind != VkString:
    raise new_exception(types.Exception, "base64_encode requires a string argument")

  let encoded = base64.encode(input.str)
  return encoded.to_value()

proc base64_decode(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "base64_decode requires a string argument")

  let input = get_positional_arg(args, 0, has_keyword_args)
  if input.kind != VkString:
    raise new_exception(types.Exception, "base64_decode requires a string argument")

  try:
    let decoded = base64.decode(input.str)
    return decoded.to_value()
  except ValueError as e:
    raise new_exception(types.Exception, "Invalid base64 string: " & e.msg)

proc trace_start(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  vm.trace = true
  return NIL

proc trace_end(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  vm.trace = false
  return NIL

proc print_stack(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  var s = "Stack: "
  for i, reg in vm.frame.stack:
    if i > 0:
      s &= ", "
    if i == vm.frame.stack_index.int:
      s &= "=> "
    s &= $vm.frame.stack[i]
  echo s
  return NIL

proc print_instructions(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  echo vm.cu
  return NIL

proc to_ctor(node: Value): Function =
  let name = "ctor"

  let matcher = new_arg_matcher()
  matcher.parse(node.gene.children[0])
  matcher.check_hint()

  var body: seq[Value] = @[]
  for i in 1..<node.gene.children.len:
    body.add node.gene.children[i]

  # body = wrap_with_try(body)
  result = new_fn(name, matcher, body)

proc class_ctor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    not_allowed("class_ctor requires arguments")

  let args_gene = create_gene_args(args, arg_count, has_keyword_args)
  let fn = to_ctor(args_gene)
  fn.ns = vm.frame.ns
  let r = new_ref(VkFunction)
  r.fn = fn
  # Get class from first argument (bound method self)
  let x = args_gene.gene.type.ref.bound_method.self
  if x.kind == VkClass:
    x.ref.class.constructor = r.to_ref_value()
  else:
    not_allowed("Constructor can only be defined on classes")

proc class_fn(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    not_allowed("class_fn requires arguments")

  let args_gene = create_gene_args(args, arg_count, has_keyword_args)
  let x = args_gene.gene.type.ref.bound_method.self
  # define a fn like method on a class
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
  case x.kind:
  of VkClass:
    let class = x.ref.class
    m.class = class
    fn.ns = class.ns
    class.methods[m.name.to_key()] = m
  else:
    not_allowed()

# AOP Aspect macro
# (aspect A [m1 m2]
#   (before m1 [args...] body...)
#   (after m2 [args...] body...)
# )
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
    
    # First child is the aspect name
    let name_val = gene.children[0]
    if name_val.kind != VkSymbol:
      not_allowed("aspect name must be a symbol")
    let name = name_val.str
    
    # Second child is the method parameters list [m1 m2]
    let params_val = gene.children[1]
    if params_val.kind != VkArray:
      not_allowed("aspect parameter list must be an array")
    
    var param_names: seq[string] = @[]
    for p in array_data(params_val):
      if p.kind == VkSymbol:
        param_names.add(p.str)
      else:
        not_allowed("aspect parameter must be a symbol")
    
    # Create the Aspect
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
    
    # Parse advice definitions (children 2+)
    for i in 2..<gene.children.len:
      let advice_def = gene.children[i]
      if advice_def.kind != VkGene:
        not_allowed("advice definition must be a gene expression")
      
      let advice_gene = advice_def.gene
      if advice_gene.children.len < 2:
        not_allowed("advice requires type and target")
      
      # advice_gene.type is the advice type (before, after, around, etc.)
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

      # First child is the target method param
      let target = advice_gene.children[0]
      if target.kind != VkSymbol:
        not_allowed("advice target must be a method parameter symbol")
      let target_name = target.str
      
      # Validate target is in param_names
      if not (target_name in param_names):
        not_allowed("advice target '" & target_name & "' is not a defined method parameter")

      var advice_val: Value
      var user_arg_count = -1
      if advice_gene.children.len == 2:
        advice_val = resolve_advice_callable(advice_gene.children[1], caller_frame)
      else:
        # Create the advice function from remaining children
        # children[1] is the args matcher, children[2..] is the body
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

        # Create scope_tracker with parameter mappings so exec_function can bind args
        var scope_tracker = new_scope_tracker()
        for m in matcher.children:
          if m.kind == MatchData and m.name_key != Key(0):
            scope_tracker.add(m.name_key)
        advice_fn.scope_tracker = scope_tracker

        let advice_fn_ref = new_ref(VkFunction)
        advice_fn_ref.fn = advice_fn
        advice_val = advice_fn_ref.to_ref_value()

      # Add to appropriate advice table
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
    
    # Create Value for the aspect
    let aspect_ref = new_ref(VkAspect)
    aspect_ref.aspect = aspect
    let aspect_val = aspect_ref.to_ref_value()
    
    # Define the aspect in caller's namespace
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

# Aspect.apply - apply aspect to a class
# (A .apply C "m1" "m2")
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
  
  # Map param names to actual method names from remaining args  
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
    # Keep existing interception wrappers so aspects chain instead of replacing each other.
    class.methods[method_key].callable = interception_val
    array_data(applied).add(interception_val)

  return applied

# Aspect.apply-fn - apply aspect to a standalone function
# (A .apply-fn fn_value "m1")
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

proc vm_compile(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    if arg_count < 1:
      not_allowed("vm_compile requires an argument")

    let compiler = Compiler(
      output: new_compilation_unit(),
      method_access_mode: MamAutoCall
    )
    let scope_tracker = vm.frame.caller_frame.scope.tracker
    # compiler.output.scope_tracker = scope_tracker
    compiler.scope_trackers.add(scope_tracker)
    compiler.compile(get_positional_arg(args, 0, has_keyword_args))
    var instrs = new_array_value()
    for instr in compiler.output.instructions:
      array_data(instrs).add instr.to_value()
    result = instrs

proc vm_push(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    not_allowed("vm_push requires an argument")
  new_instr(IkPushValue, get_positional_arg(args, 0, has_keyword_args))

proc vm_add(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  new_instr(IkAdd)

proc current_ns(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # Return the current namespace
  let r = new_ref(VkNamespace)
  r.ns = vm.frame.ns
  result = r.to_ref_value()

# vm_not function removed - now handled by IkNot instruction at compile time

# vm_spread function removed - ... is now handled as compile-time keyword

proc vm_parse(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # Parse Gene code from string
  if arg_count != 1:
    not_allowed("$parse expects exactly 1 argument")
  let arg = get_positional_arg(args, 0, has_keyword_args)
  case arg.kind:
    of VkString:
      let code = arg.str
      # Use the actual Gene parser to parse the code
      try:
        let parsed = read_all(code)
        if parsed.len > 0:
          return parsed[0]
        else:
          return NIL
      except:
        # Fallback to simple parsing for basic literals
        case code:
          of "true":
            return TRUE
          of "false":
            return FALSE
          of "nil":
            return NIL
          else:
            # Try to parse as number
            try:
              let int_val = parseInt(code)
              return int_val.to_value()
            except ValueError:
              try:
                let float_val = parseFloat(code)
                return float_val.to_value()
              except ValueError:
                # Return as symbol for now
                return code.to_symbol_value()
    else:
      not_allowed("$parse expects a string argument")

proc vm_with(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # $with sets self to the first argument and executes the body, returns the original value
  if arg_count < 2:
    not_allowed("$with expects at least 2 arguments")

  let original_value = get_positional_arg(args, 0, has_keyword_args)
  # Self is now managed through arguments, not frame field
  # The compiler should handle passing the value as the first argument

  # Execute the body (all arguments after the first)
  for i in 1..<get_positional_count(arg_count, has_keyword_args):
    discard # Body execution would happen during compilation/evaluation

  return original_value

proc vm_tap(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # $tap executes the body with self set to the first argument, returns the original value
  if arg_count < 2:
    not_allowed("$tap expects at least 2 arguments")

  let original_value = get_positional_arg(args, 0, has_keyword_args)

  # If second argument is a symbol, bind it to the value
  var binding_name: string = ""
  var body_start_index = 1
  if arg_count > 2:
    let second_arg = get_positional_arg(args, 1, has_keyword_args)
    if second_arg.kind == VkSymbol:
      binding_name = second_arg.str
      body_start_index = 2

  # Self is now managed through arguments
  # The compiler should handle passing the value as the first argument

  # Execute the body
  for i in body_start_index..<get_positional_count(arg_count, has_keyword_args):
    discard # Body execution would happen during compilation/evaluation

  return original_value

# String interpolation handler
proc vm_str_interpolation(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  # #Str concatenates all arguments as strings
  var result = ""
  for i in 0..<get_positional_count(arg_count, has_keyword_args):
    let child = get_positional_arg(args, i, has_keyword_args)
    case child.kind:
    of VkString:
      result.add(child.str)
    of VkInt:
      result.add($child.int64)
    of VkBool:
      result.add(if child.bool: "true" else: "false")
    of VkNil:
      result.add("nil")
    of VkChar:
      result.add($chr((child.raw and 0xFF).int))
    of VkFloat:
      result.add($child.float)
    else:
      # For other types, use $ operator
      result.add($child)

  return result.to_value()

proc vm_eval(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    # This function is not used - eval is handled by IkEval instruction
    # The compiler generates IkEval instructions for each argument
    not_allowed("vm_eval should not be called directly")

# TODO: Implement while loop properly - needs compiler-level support like loop/if


# Sleep functions
proc gene_sleep(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "sleep requires 1 argument")

  let duration_arg = get_positional_arg(args, 0, has_keyword_args)
  var duration_ms: int

  case duration_arg.kind:
    of VkInt:
      duration_ms = duration_arg.int64.int
    of VkFloat:
      duration_ms = (duration_arg.float64 * 1000).int
    else:
      raise new_exception(types.Exception, "sleep requires a number (milliseconds)")

  # If there are no pending futures, just sleep normally
  if vm.pending_futures.len == 0:
    sleep(duration_ms)
    return NIL

  # Sleep in small chunks and poll event loop to allow async operations to progress
  let chunk_size = 50  # Poll every 50ms when there are pending futures
  var remaining = duration_ms
  while remaining > 0:
    let sleep_time = min(remaining, chunk_size)
    sleep(sleep_time)
    remaining -= sleep_time

    # Poll event loop - callbacks will update future states
    {.cast(gcsafe).}:
      try:
        # Save old states before polling
        var old_states = newSeq[FutureState](vm.pending_futures.len)
        for i in 0..<vm.pending_futures.len:
          old_states[i] = vm.pending_futures[i].state

        # Poll to allow async operations to progress and fire callbacks
        if hasPendingOperations():
          poll(0)

        # Check for completed futures and execute their user callbacks
        var i = 0
        while i < vm.pending_futures.len:
          let future_obj = vm.pending_futures[i]
          let old_state = old_states[i]

          # If future just completed (Nim callback fired), execute user callbacks
          if old_state == FsPending and future_obj.state != FsPending:
            if future_obj.state == FsSuccess:
              for callback in future_obj.success_callbacks:
                case callback.kind:
                  of VkFunction, VkBlock:
                    discard vm_exec_callable(vm, callback, @[future_obj.value])
                  of VkNativeFn:
                    var args_arr = [future_obj.value]
                    discard call_native_fn(callback.ref.native_fn, vm, args_arr)
                  else:
                    discard
            elif future_obj.state == FsFailure:
              for callback in future_obj.failure_callbacks:
                case callback.kind:
                  of VkFunction, VkBlock:
                    discard vm_exec_callable(vm, callback, @[future_obj.value])
                  of VkNativeFn:
                    var args_arr = [future_obj.value]
                    discard call_native_fn(callback.ref.native_fn, vm, args_arr)
                  else:
                    discard

          # If future completed, remove from pending list
          if future_obj.state != FsPending:
            vm.pending_futures.delete(i)
          else:
            i.inc()
      except ValueError:
        discard

  return NIL

proc gene_sleep_async(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "sleep_async requires 1 argument")

  let duration_arg = get_positional_arg(args, 0, has_keyword_args)
  var duration_ms: int

  case duration_arg.kind:
    of VkInt:
      duration_ms = duration_arg.int64.int
    of VkFloat:
      duration_ms = (duration_arg.float64 * 1000).int
    else:
      raise new_exception(types.Exception, "sleep_async requires a number (milliseconds)")

  # Create Gene future first
  let gene_future_obj = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil
  )

  # Create Nim future and add callback to complete Gene future
  let nim_sleep_future = sleepAsync(duration_ms)
  nim_sleep_future.addCallback proc() {.gcsafe.} =
    gene_future_obj.state = FsSuccess
    gene_future_obj.value = NIL

  let gene_future_val = new_ref(VkFuture)
  gene_future_val.future = gene_future_obj
  let result = gene_future_val.to_ref_value()

  # Add to VM's pending futures list so it gets polled
  vm.pending_futures.add(gene_future_obj)
  vm.poll_enabled = true

  return result

# I/O functions
proc file_read(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "File/read requires 1 argument")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/read requires a string path")

  let path = path_arg.str
  try:
    let content = readFile(path)
    return content.to_value()
  except IOError as e:
    raise new_exception(types.Exception, "Failed to read file '" & path & "': " & e.msg)

proc file_write(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "File/write requires 2 arguments")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  let content_arg = get_positional_arg(args, 1, has_keyword_args)

  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/write requires a string path")
  if content_arg.kind != VkString:
    raise new_exception(types.Exception, "File/write requires string content")

  let path = path_arg.str
  let content = content_arg.str

  try:
    writeFile(path, content)
    return NIL
  except IOError as e:
    raise new_exception(types.Exception, "Failed to write file '" & path & "': " & e.msg)

proc file_read_async(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 1:
    raise new_exception(types.Exception, "File/read_async requires 1 argument")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/read_async requires a string path")

  let path = path_arg.str

  # Create Gene future first
  let gene_future_obj = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil
  )

  # Try to open file and create async read operation
  try:
    let file = openAsync(path, fmRead)
    let nim_read_future = file.readAll()

    # Add callback to complete Gene future when Nim future completes
    nim_read_future.addCallback proc() {.gcsafe.} =
      try:
        let content = nim_read_future.read()
        file.close()
        gene_future_obj.state = FsSuccess
        gene_future_obj.value = content.to_value()
      except IOError as e:
        gene_future_obj.state = FsFailure
        gene_future_obj.value = new_str_value("Failed to read file '" & path & "': " & e.msg)
      except CatchableError as e:
        gene_future_obj.state = FsFailure
        gene_future_obj.value = new_str_value("Error reading file: " & e.msg)
  except IOError as e:
    # File open failed - create a failed future immediately
    gene_future_obj.state = FsFailure
    gene_future_obj.value = new_str_value("Failed to open file '" & path & "': " & e.msg)
  except CatchableError as e:
    gene_future_obj.state = FsFailure
    gene_future_obj.value = new_str_value("Error opening file: " & e.msg)

  let gene_future_val = new_ref(VkFuture)
  gene_future_val.future = gene_future_obj
  let result = gene_future_val.to_ref_value()

  # Add to VM's pending futures list (even if already failed)
  vm.pending_futures.add(gene_future_obj)
  vm.poll_enabled = true

  return result

proc file_write_async(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  if arg_count < 2:
    raise new_exception(types.Exception, "File/write_async requires 2 arguments")

  let path_arg = get_positional_arg(args, 0, has_keyword_args)
  let content_arg = get_positional_arg(args, 1, has_keyword_args)

  if path_arg.kind != VkString:
    raise new_exception(types.Exception, "File/write_async requires a string path")
  if content_arg.kind != VkString:
    raise new_exception(types.Exception, "File/write_async requires string content")

  let path = path_arg.str
  let content = content_arg.str

  # Create Gene future first
  let gene_future_obj = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil
  )

  # Create Nim future for async file writing
  let file = openAsync(path, fmWrite)
  let nim_write_future = file.write(content)

  # Add callback to complete Gene future when Nim future completes
  nim_write_future.addCallback proc() {.gcsafe.} =
    try:
      # Write future is Future[void], just check if it failed
      if nim_write_future.failed:
        gene_future_obj.state = FsFailure
        gene_future_obj.value = new_str_value("Failed to write file '" & path & "'")
      else:
        file.close()
        gene_future_obj.state = FsSuccess
        gene_future_obj.value = NIL
    except IOError as e:
      gene_future_obj.state = FsFailure
      gene_future_obj.value = new_str_value("Failed to write file '" & path & "': " & e.msg)
    except CatchableError as e:
      gene_future_obj.state = FsFailure
      gene_future_obj.value = new_str_value("Error writing file: " & e.msg)

  let gene_future_val = new_ref(VkFuture)
  gene_future_val.future = gene_future_obj
  let result = gene_future_val.to_ref_value()

  # Add to VM's pending futures list
  vm.pending_futures.add(gene_future_obj)
  vm.poll_enabled = true

  return result

proc init_gene_core_functions() =
  App.app.gene_ns.ns["debug".to_key()] = debug
  App.app.gene_ns.ns["println".to_key()] = println
  App.app.gene_ns.ns["print".to_key()] = print
  App.app.gene_ns.ns["assert".to_key()] = gene_assert
  App.app.gene_ns.ns["base64_encode".to_key()] = base64_encode
  App.app.gene_ns.ns["base64_decode".to_key()] = base64_decode
  App.app.gene_ns.ns["trace_start".to_key()] = trace_start
  App.app.gene_ns.ns["trace_end".to_key()] = trace_end
  App.app.gene_ns.ns["print_stack".to_key()] = print_stack
  App.app.gene_ns.ns["print_instructions".to_key()] = print_instructions
  App.app.gene_ns.ns["ns".to_key()] = current_ns
  # not and ... are now handled by compile-time instructions, no need to register
  App.app.gene_ns.ns["parse".to_key()] = vm_parse.to_value()  # $parse resolves via global parse
  App.app.gene_ns.ns["with".to_key()] = vm_with.to_value()    # $with resolves via global with
  App.app.gene_ns.ns["tap".to_key()] = vm_tap.to_value()      # $tap resolves via global tap
  App.app.gene_ns.ns["eval".to_key()] = vm_eval.to_value()    # eval function
  App.app.gene_ns.ns["repl".to_key()] = NativeFn(core_repl).to_value()  # $repl resolves via global repl
  App.app.gene_ns.ns["types_equivalent".to_key()] = core_types_equivalent.to_value()
  App.app.gene_ns.ns["types_equiv".to_key()] = core_types_equivalent.to_value()

  var sleep_ref = new_ref(VkNativeFn)
  sleep_ref.native_fn = gene_sleep
  App.app.gene_ns.ns["sleep".to_key()] = sleep_ref.to_ref_value()

  var sleep_async_ref = new_ref(VkNativeFn)
  sleep_async_ref.native_fn = gene_sleep_async
  App.app.gene_ns.ns["sleep_async".to_key()] = sleep_async_ref.to_ref_value()

  App.app.global_ns.ns["parse".to_key()] = vm_parse.to_value()
  App.app.global_ns.ns["with".to_key()] = vm_with.to_value()
  App.app.global_ns.ns["tap".to_key()] = vm_tap.to_value()
  App.app.global_ns.ns["eval".to_key()] = vm_eval.to_value()
  App.app.global_ns.ns["#Str".to_key()] = vm_str_interpolation.to_value()
  App.app.global_ns.ns["not_found".to_key()] = NOT_FOUND

  # Result type constructors: Ok and Err
  # (Ok value) creates a Gene with type "Ok" and the value as child
  # (Err value) creates a Gene with type "Err" and the value as child
  proc vm_ok(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let val = if get_positional_count(arg_count, has_keyword_args) > 0:
      get_positional_arg(args, 0, has_keyword_args)
    else:
      NIL
    var gene = new_gene("Ok".to_symbol_value())
    gene.children.add(val)
    # Copy any properties from args
    if has_keyword_args:
      for i in 0..<arg_count:
        let arg = args[i]
        if arg.kind == VkGene and arg.gene != nil:
          for k, v in arg.gene.props:
            gene.props[k] = v
          break
    return gene.to_gene_value()

  proc vm_err(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let val = if get_positional_count(arg_count, has_keyword_args) > 0:
      get_positional_arg(args, 0, has_keyword_args)
    else:
      NIL
    var gene = new_gene("Err".to_symbol_value())
    gene.children.add(val)
    # Copy any properties (like ^code, ^context, etc.)
    if has_keyword_args:
      for i in 0..<arg_count:
        let arg = args[i]
        if arg.kind == VkGene and arg.gene != nil:
          for k, v in arg.gene.props:
            gene.props[k] = v
          break
    return gene.to_gene_value()

  # Option type constructors: Some and None
  proc vm_some(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let val = if get_positional_count(arg_count, has_keyword_args) > 0:
      get_positional_arg(args, 0, has_keyword_args)
    else:
      NIL
    var gene = new_gene("Some".to_symbol_value())
    gene.children.add(val)
    return gene.to_gene_value()

  # None is just a symbol, not a function
  let none_gene = new_gene("None".to_symbol_value())
  let none_val = none_gene.to_gene_value()

  var ok_fn = new_ref(VkNativeFn)
  ok_fn.native_fn = vm_ok
  App.app.global_ns.ns["Ok".to_key()] = ok_fn.to_ref_value()

  var err_fn = new_ref(VkNativeFn)
  err_fn.native_fn = vm_err
  App.app.global_ns.ns["Err".to_key()] = err_fn.to_ref_value()

  var some_fn = new_ref(VkNativeFn)
  some_fn.native_fn = vm_some
  App.app.global_ns.ns["Some".to_key()] = some_fn.to_ref_value()

  App.app.global_ns.ns["None".to_key()] = none_val

proc init_os_io_namespaces() =
  proc os_exec_native(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("os.exec requires a command string")
    let cmd_arg = get_positional_arg(args, 0, has_keyword_args)
    if cmd_arg.kind != VkString:
      not_allowed("os.exec expects a string command")
    let (output, _) = execCmdEx(cmd_arg.str)
    output.to_value()

  let os_ns = new_namespace("os")
  var os_exec_fn = new_ref(VkNativeFn)
  os_exec_fn.native_fn = os_exec_native
  os_ns["exec".to_key()] = os_exec_fn.to_ref_value()
  App.app.gene_ns.ref.ns["os".to_key()] = os_ns.to_value()

  let io_ns = new_namespace("io")

  var read_fn = new_ref(VkNativeFn)
  read_fn.native_fn = file_read
  io_ns["read".to_key()] = read_fn.to_ref_value()

  var write_fn = new_ref(VkNativeFn)
  write_fn.native_fn = file_write
  io_ns["write".to_key()] = write_fn.to_ref_value()

  var read_async_fn = new_ref(VkNativeFn)
  read_async_fn.native_fn = file_read_async
  io_ns["read_async".to_key()] = read_async_fn.to_ref_value()

  var write_async_fn = new_ref(VkNativeFn)
  write_async_fn.native_fn = file_write_async
  io_ns["write_async".to_key()] = write_async_fn.to_ref_value()

  App.app.gene_ns.ref.ns["io".to_key()] = io_ns.to_value()

proc init_stdlib_namespaces() =
  stdlib_math.init_math_namespace(App.app.global_ns.ref.ns)
  stdlib_io.init_io_namespace(App.app.global_ns.ref.ns)
  stdlib_system.init_system_namespace(App.app.global_ns.ref.ns)

proc init_class_class(object_class: Class) =
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

  r = new_ref(VkClass)
  r.class = class
  App.app.class_class = r.to_ref_value()
  App.app.gene_ns.ns["Class".to_key()] = App.app.class_class
  App.app.global_ns.ns["Class".to_key()] = App.app.class_class

proc init_vm_namespace() =
  let vm_ns = new_namespace("vm")
  App.app.gene_ns.ns["vm".to_key()] = vm_ns.to_value()
  vm_ns["compile".to_key()] = vm_compile.to_value()
  vm_ns["PUSH".to_key()] = vm_push.to_value()
  vm_ns["ADD".to_key()] = vm_add.to_value()
  vm_ns["print_stack".to_key()] = core_vm_print_stack.to_value()
  vm_ns["print_instructions".to_key()] = core_vm_print_instructions.to_value()
  App.app.global_ns.ns["vm".to_key()] = vm_ns.to_value()

proc init_gene_namespace*() =
  if types.gene_namespace_initialized:
    return
  types.gene_namespace_initialized = true
  let object_class = stdlib_classes.init_basic_classes()
  stdlib_strings.init_string_class(object_class)
  stdlib_regex.init_regex_class(object_class)

  stdlib_classes.init_symbol_classes(object_class)

  stdlib_collections.init_collection_classes(object_class)

  stdlib_dates.init_date_classes(object_class)

  stdlib_json.init_json_namespace()
  stdlib_dates.init_date_functions()

  stdlib_selectors.init_selector_class(object_class)
  
  stdlib_collections.init_set_class(object_class)
  stdlib_gene_meta.init_gene_and_meta_classes(object_class)

  init_gene_core_functions()

  init_os_io_namespaces()
  init_stdlib_namespaces()

  stdlib_classes.init_class_class(object_class)
  init_vm_namespace()

  init_thread_class()

# Utility function: $tap - applies operations to a value and returns it
proc core_tap(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if get_positional_count(arg_count, has_keyword_args) == 0:
    return NIL

  let value = get_positional_arg(args, 0, has_keyword_args)

  # For now, implement a simple version that compiles method calls
  # This is a simplified approach for the HTTP todo app
  for i in 1..<get_positional_count(arg_count, has_keyword_args):
    let operation = get_positional_arg(args, i, has_keyword_args)

    if operation.kind == VkGene and operation.gene.children.len > 0:
      let method_name = operation.gene.children[0]
      if method_name.kind == VkSymbol:
        # For now, we'll just simulate the method call by doing nothing
        # TODO: Implement proper method chaining in the future
        discard
      else:
        raise new_exception(types.Exception, "$tap operations must start with a symbol (method name)")
    else:
      raise new_exception(types.Exception, "$tap operations must be Gene expressions")

  return value

# Utility function: $if_main - executes code only when running as main script
proc core_if_main(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  # For now, just execute the first argument since we don't have import tracking
  if get_positional_count(arg_count, has_keyword_args) > 0:
    let code = get_positional_arg(args, 0, has_keyword_args)
    return code
  return NIL

proc init_stdlib*() =
  # Initialize gene namespace first (classes, methods, etc.)
  init_gene_namespace()

  var global_ns = App.app.global_ns.ns
  global_ns["print".to_key()] = core_print.to_value()
  global_ns["println".to_key()] = core_println.to_value()

  # Collections
  global_ns["len".to_key()] = NativeFn(core_len).to_value()
  global_ns["types_equivalent".to_key()] = core_types_equivalent.to_value()
  global_ns["types_equiv".to_key()] = core_types_equivalent.to_value()

  # Assertions and debugging
  global_ns["assert".to_key()] = core_assert.to_value()
  global_ns["debug".to_key()] = core_debug.to_value()
  global_ns["trace_start".to_key()] = core_trace_start.to_value()
  global_ns["trace_end".to_key()] = core_trace_end.to_value()
  global_ns["__contracts_enabled__".to_key()] = core_contracts_enabled.to_value()
  global_ns["__contract_violation__".to_key()] = core_contract_violation.to_value()

  # Timing
  global_ns["sleep".to_key()] = core_sleep.to_value()
  global_ns["run_forever".to_key()] = core_run_forever.to_value()
  global_ns["stop_scheduler".to_key()] = core_stop_scheduler.to_value()

  # Threading
  global_ns["keep_alive".to_key()] = keep_alive_fn.to_value()

  # Environment
  global_ns["get_env".to_key()] = core_get_env.to_value()
  global_ns["set_env".to_key()] = core_set_env.to_value()
  global_ns["has_env".to_key()] = core_has_env.to_value()

  # Encoding
  global_ns["base64".to_key()] = core_base64.to_value()
  global_ns["base64_decode".to_key()] = core_base64_decode.to_value()

  # Utility functions
  global_ns["$tap".to_key()] = core_tap.to_value()
  global_ns["$if_main".to_key()] = core_if_main.to_value()
  global_ns["$repl".to_key()] = NativeFn(core_repl).to_value()
  
  stdlib_aspects.init_aspect_support()

  load_logging_config()

  load_logging_config()

  # OpenAI API functions
  when not defined(noExtensions) and not defined(noai):
    var ai_ns_val = NIL
    if App.app.genex_ns.kind == VkNamespace:
      ai_ns_val = App.app.genex_ns.ref.ns["ai".to_key()]

    var ai_ns: Namespace
    if ai_ns_val.kind == VkNamespace:
      ai_ns = ai_ns_val.ref.ns
    else:
      ai_ns = new_namespace("ai")

    # OpenAI client creation and operations
    ai_ns["new_client".to_key()] = vm_openai_new_client.to_value()
    ai_ns["chat".to_key()] = vm_openai_chat.to_value()
    ai_ns["embeddings".to_key()] = vm_openai_embeddings.to_value()
    ai_ns["respond".to_key()] = vm_openai_respond.to_value()
    ai_ns["stream".to_key()] = vm_openai_stream.to_value()

    let documents_ns = new_namespace("documents")
    documents_ns["extract_pdf".to_key()] = vm_ai_documents_extract_pdf.to_value()
    documents_ns["extract_image".to_key()] = vm_ai_documents_extract_image.to_value()
    documents_ns["chunk".to_key()] = vm_ai_documents_chunk.to_value()
    documents_ns["extract_and_chunk".to_key()] = vm_ai_documents_extract_and_chunk.to_value()
    documents_ns["save_upload".to_key()] = vm_ai_documents_save_upload.to_value()
    documents_ns["validate_upload".to_key()] = vm_ai_documents_validate_upload.to_value()
    documents_ns["extract_upload".to_key()] = vm_ai_documents_extract_upload.to_value()
    ai_ns["documents".to_key()] = documents_ns.to_value()

    # Register the AI namespace in genex namespace
    if App.app.genex_ns.kind == VkNamespace:
      App.app.genex_ns.ref.ns["ai".to_key()] = ai_ns.to_value()

    # Also register in global namespace for direct access
    global_ns["openai_new_client".to_key()] = vm_openai_new_client.to_value()
    global_ns["openai_chat".to_key()] = vm_openai_chat.to_value()
    global_ns["openai_embeddings".to_key()] = vm_openai_embeddings.to_value()
    global_ns["openai_respond".to_key()] = vm_openai_respond.to_value()
    global_ns["openai_stream".to_key()] = vm_openai_stream.to_value()

    # Convenience aliases
    global_ns["OpenAIClient".to_key()] = ai_ns.to_value()
    # App.app.global_ns.ns["OpenAIClient".to_key()] = ai_ns.to_value()


{.pop.}
