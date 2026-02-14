import strutils

import ../types
import ./classes
import ./regex

proc init_string_class*(object_class: Class) =
  var r: ptr Reference
  let string_class = new_class("String")
  string_class.parent = object_class
  string_class.def_native_method("to_s", object_to_s_method)

  proc string_constructor(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let positional = get_positional_count(arg_count, has_keyword_args)
    var buffer = newStringOfCap(32)
    for i in 0..<positional:
      let arg = get_positional_arg(args, i, has_keyword_args)
      buffer.add(display_value(arg, true))
    buffer.to_value()

  string_class.def_native_constructor(string_constructor)

  proc ensure_mutable_string(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], has_keyword_args: bool): Value =
    let self_index = if has_keyword_args: 1 else: 0
    let original = args[self_index]
    let raw = cast[uint64](original)
    let tag = raw and 0xFFFF_0000_0000_0000u64

    case tag
    of STRING_TAG:
      return original
    else:
      return original

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
