import strutils, unicode

import ../types
import ../text_utils
import ./classes
import ./regex

proc init_string_class*(object_class: Class) =
  var r: ptr Reference
  let string_class = new_class("String")
  string_class.parent = object_class
  r = new_ref(VkClass)
  r.class = string_class
  let string_class_value = r.to_ref_value()
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
    ## Return the receiver string ready for in-place mutation.
    ## IkPushValue always copies string literals on push so each variable binding
    ## gets a private ptr String (ref_count=1 at the alloc site). The interned
    ## instruction constant is therefore never reachable here.
    ## A ref_count > 1 check is incorrect: Nim's =copy hook retains Values when
    ## they are stored in the temporary arg seq (invoke_method_value), so an
    ## ordinary local variable appears shared during the call even though it is not.
    let self_index = if has_keyword_args: 1 else: 0
    return args[self_index]

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
  # append is variadic; keep metadata open until varargs typing is supported.
  string_class.def_native_method("append", append_fn.native_fn)

  proc string_length(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "String.length requires self argument")

    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      raise new_exception(types.Exception, "length can only be called on a string")

    return utf8_char_len(self_arg.str).int64.to_value()

  var length_fn = new_ref(VkNativeFn)
  length_fn.native_fn = string_length
  string_class.def_native_method("length", length_fn.native_fn, @[], App.app.int_class)
  string_class.def_native_method("size", length_fn.native_fn, @[], App.app.int_class)

  proc string_bytesize(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.bytesize requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("bytesize must be called on a string")
    utf8_byte_len(self_arg.str).int64.to_value()

  string_class.def_native_method("bytesize", string_bytesize, @[], App.app.int_class)

  proc string_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.empty requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("empty must be called on a string")
    (self_arg.str.len == 0).to_value()

  string_class.def_native_method("empty", string_empty)
  string_class.def_native_method("empty?", string_empty)

  proc string_not_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.not_empty? requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("not_empty? must be called on a string")
    (self_arg.str.len != 0).to_value()

  string_class.def_native_method("not_empty?", string_not_empty)

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

  string_class.def_native_method("to_i", string_to_i, @[], App.app.int_class)

  proc string_to_f(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.to_f requires self argument")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("to_f can only be called on a string")
    let trimmed = self_arg.str.strip()
    if trimmed.len == 0:
      not_allowed("to_f requires a numeric string")
    try:
      return trimmed.parseFloat().to_value()
    except ValueError:
      not_allowed("to_f requires a numeric string")

  string_class.def_native_method("to_f", string_to_f, @[], App.app.float_class)

  proc string_to_upper(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "String.to_upper requires self argument")

    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      raise new_exception(types.Exception, "to_upper can only be called on a string")

    return unicode.toUpper(self_arg.str).to_value()

  var to_upper_fn = new_ref(VkNativeFn)
  to_upper_fn.native_fn = string_to_upper
  string_class.def_native_method("to_upper", to_upper_fn.native_fn, @[], string_class_value)

  proc string_to_lower(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 1:
      raise new_exception(types.Exception, "String.to_lower requires self argument")

    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      raise new_exception(types.Exception, "to_lower can only be called on a string")

    return unicode.toLower(self_arg.str).to_value()

  var to_lower_fn = new_ref(VkNativeFn)
  to_lower_fn.native_fn = string_to_lower
  string_class.def_native_method("to_lower", to_lower_fn.native_fn, @[], string_class_value)
  string_class.def_native_method("to_lowercase", to_lower_fn.native_fn)

  proc string_to_uppercase(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    string_to_upper(vm, args, arg_count, has_keyword_args)

  proc string_to_lowercase(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    string_to_lower(vm, args, arg_count, has_keyword_args)

  proc string_capitalize(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.capitalize requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("capitalize must be called on a string")
    if self_arg.str.len == 0:
      return "".to_value()

    let first = unicode.toUpper(utf8_char_str_at(self_arg.str, 0))
    let rest =
      if utf8_char_len(self_arg.str) > 1:
        unicode.toLower(unicode.runeSubStr(self_arg.str, 1))
      else:
        ""
    (first & rest).to_value()

  proc string_reverse(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.reverse requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("reverse must be called on a string")
    let runes = self_arg.str.toRunes()
    var buffer = newStringOfCap(self_arg.str.len)
    if runes.len > 0:
      for i in countdown(runes.len - 1, 0):
        buffer.add(runes[i])
    buffer.to_value()

  string_class.def_native_method("to_uppercase", string_to_uppercase)
  string_class.def_native_method("to_lowercase", string_to_lowercase)
  string_class.def_native_method("upper", to_upper_fn.native_fn, @[], string_class_value)
  string_class.def_native_method("lower", to_lower_fn.native_fn, @[], string_class_value)
  string_class.def_native_method("upcase", to_upper_fn.native_fn, @[], string_class_value)
  string_class.def_native_method("downcase", to_lower_fn.native_fn, @[], string_class_value)
  string_class.def_native_method("capitalize", string_capitalize)
  string_class.def_native_method("reverse", string_reverse)

  proc string_substr(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.substr requires start index")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("substr must be called on a string")
    let s = self_arg.str
    let len = utf8_char_len(s)
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
      return unicode.runeSubStr(s, start_idx).to_value()

    let end_idx64 = get_positional_arg(args, 2, has_keyword_args).to_int()
    var end_idx = adjust(end_idx64, false)
    if end_idx < start_idx:
      return "".to_value()
    result = unicode.runeSubStr(s, start_idx, end_idx - start_idx + 1).to_value()

  string_class.def_native_method("substr", string_substr)

  proc string_split(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.split requires separator")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("split must be called on a string")
    let sep_arg = get_positional_arg(args, 1, has_keyword_args)
    case sep_arg.kind
    of VkString:
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
      result = arr_ref
    of VkRegex:
      let limit = if get_positional_count(arg_count, has_keyword_args) >= 3:
        max(1, get_positional_arg(args, 2, has_keyword_args).to_int().int)
      else:
        0
      result = regex_split_values(self_arg.str, sep_arg, limit)
    else:
      not_allowed("split separator must be a string or Regexp")

  string_class.def_native_method("split", string_split)

  proc normalize_search_start(s: string, raw_offset: int64): int {.inline, gcsafe.} =
    let char_len = utf8_char_len(s)
    var offset = raw_offset.int
    if offset < 0:
      offset = char_len + offset
    if offset < 0:
      0
    elif offset > char_len:
      char_len
    else:
      offset

  proc normalize_search_limit(s: string, raw_offset: int64): int {.inline, gcsafe.} =
    let char_len = utf8_char_len(s)
    if char_len == 0:
      return -1
    var offset = raw_offset.int
    if offset < 0:
      offset = char_len + offset
    if offset < 0:
      return -1
    min(offset, char_len - 1)

  proc string_index(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("String.index requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("index must be called on a string")
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    let start_char = if pos_count >= 3:
      normalize_search_start(self_arg.str, get_positional_arg(args, 2, has_keyword_args).to_int())
    else:
      0
    let start_byte = utf8_byte_offset_for_char_pos(self_arg.str, start_char)
    case pattern_val.kind
    of VkString:
      let pos = if pattern_val.str.len == 0:
        start_byte
      else:
        self_arg.str.find(pattern_val.str, start_byte)
      if pos < 0:
        result = (-1).to_value()
      else:
        result = utf8_char_pos_for_byte_offset(self_arg.str, pos).to_value()
    of VkRegex:
      let (first, _) = regex_find_byte_bounds(self_arg.str, pattern_val, start_byte)
      if first < 0:
        result = (-1).to_value()
      else:
        result = utf8_char_pos_for_byte_offset(self_arg.str, first).to_value()
    else:
      not_allowed("String.index expects a Regexp or string pattern")

  string_class.def_native_method("index", string_index)

  proc string_rindex(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("String.rindex requires a pattern")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("rindex must be called on a string")
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    let char_len = utf8_char_len(self_arg.str)
    let limit_char = if pos_count >= 3:
      normalize_search_limit(self_arg.str, get_positional_arg(args, 2, has_keyword_args).to_int())
    else:
      char_len - 1
    if limit_char < 0:
      return (-1).to_value()
    case pattern_val.kind
    of VkString:
      if pattern_val.str.len == 0:
        return min(limit_char + 1, char_len).to_value()
      var search_byte = 0
      var last_found = -1
      while search_byte <= self_arg.str.len:
        let pos = self_arg.str.find(pattern_val.str, search_byte)
        if pos < 0:
          break
        let char_pos = utf8_char_pos_for_byte_offset(self_arg.str, pos)
        if char_pos > limit_char:
          break
        last_found = char_pos
        search_byte = pos + 1
      result = last_found.to_value()
    of VkRegex:
      var search_byte = 0
      var last_found = -1
      while search_byte <= self_arg.str.len:
        let (first, last) = regex_find_byte_bounds(self_arg.str, pattern_val, search_byte)
        if first < 0:
          break
        let char_pos = utf8_char_pos_for_byte_offset(self_arg.str, first)
        if char_pos > limit_char:
          break
        last_found = char_pos
        discard last
        search_byte = first + 1
      result = last_found.to_value()
    else:
      not_allowed("String.rindex expects a Regexp or string pattern")

  string_class.def_native_method("rindex", string_rindex)

  proc string_trim(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.trim requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("trim must be called on a string")
    unicode.strip(self_arg.str).to_value()

  string_class.def_native_method("trim", string_trim)
  string_class.def_native_method("strip", string_trim)

  proc string_lstrip(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.lstrip requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("lstrip must be called on a string")
    unicode.strip(self_arg.str, leading = true, trailing = false).to_value()

  proc string_rstrip(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.rstrip requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("rstrip must be called on a string")
    unicode.strip(self_arg.str, leading = false, trailing = true).to_value()

  string_class.def_native_method("lstrip", string_lstrip)
  string_class.def_native_method("rstrip", string_rstrip)

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
  string_class.def_native_method("start_with?", string_starts_with)
  string_class.def_native_method("end_with?", string_ends_with)

  proc string_char_at(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.char_at requires index")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString or idx_val.kind != VkInt:
      not_allowed("char_at expects string and integer")
    let idx = idx_val.int64.int
    if idx < 0 or idx >= utf8_char_len(self_arg.str):
      not_allowed("char_at index out of bounds")
    utf8_char_at(self_arg.str, idx).to_value()

  string_class.def_native_method("char_at", string_char_at)

  proc string_byte_at(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.byte_at requires index")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let idx_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString or idx_val.kind != VkInt:
      not_allowed("byte_at expects string and integer")
    var idx = idx_val.int64.int
    if idx < 0:
      idx = self_arg.str.len + idx
    if idx < 0 or idx >= self_arg.str.len:
      not_allowed("byte_at index out of bounds")
    self_arg.str[idx].ord.to_value()

  string_class.def_native_method("byte_at", string_byte_at)

  proc string_chars(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.chars requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("chars must be called on a string")
    var chars = new_array_value()
    for rune in self_arg.str.runes:
      array_data(chars).add(rune.to_value())
    chars

  proc string_each_byte(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.each_byte requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("each_byte must be called on a string")
    var values = new_array_value()
    for ch in self_arg.str:
      array_data(values).add(ch.ord.to_value())
    values

  proc string_bytes(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("String.bytes requires self")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("bytes must be called on a string")
    var data = newSeq[uint8](self_arg.str.len)
    for i in 0..<self_arg.str.len:
      data[i] = self_arg.str[i].ord.uint8
    new_bytes_value(data)

  proc string_byteslice(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("String.byteslice requires start index")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("byteslice must be called on a string")
    let byte_len = self_arg.str.len
    if byte_len == 0:
      return new_bytes_value(newSeq[uint8]())

    proc adjust(idx: int64; allowLen: bool): int =
      var res = idx.int
      if res < 0:
        res = byte_len + res
      if res < 0:
        res = 0
      if allowLen:
        if res > byte_len:
          res = byte_len
      else:
        if res >= byte_len:
          res = byte_len - 1
      res

    let start_idx = adjust(get_positional_arg(args, 1, has_keyword_args).to_int(), true)
    if start_idx >= byte_len:
      return new_bytes_value(newSeq[uint8]())

    let end_idx = if pos_count >= 3:
      adjust(get_positional_arg(args, 2, has_keyword_args).to_int(), false)
    else:
      byte_len - 1
    if end_idx < start_idx:
      return new_bytes_value(newSeq[uint8]())

    var data = newSeq[uint8](end_idx - start_idx + 1)
    var target = 0
    for i in start_idx..end_idx:
      data[target] = self_arg.str[i].ord.uint8
      target.inc()
    new_bytes_value(data)

  string_class.def_native_method("bytes", string_bytes)
  string_class.def_native_method("to_bytes", string_bytes)
  string_class.def_native_method("byteslice", string_byteslice)
  string_class.def_native_method("byte_slice", string_byteslice)
  string_class.def_native_method("chars", string_chars)
  string_class.def_native_method("each_char", string_chars)
  string_class.def_native_method("each_byte", string_each_byte)

  proc string_match(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.match requires a Regexp")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("match must be called on a string")
    if pattern_val.kind != VkRegex:
      not_allowed("String.match requires a Regexp")
    regex_process_match(self_arg.str, pattern_val)

  string_class.def_native_method("match", string_match)

  proc string_match_predicate(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("String.match? requires a Regexp")
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString:
      not_allowed("match? must be called on a string")
    if pattern_val.kind != VkRegex:
      not_allowed("String.match? requires a Regexp")
    regex_match_bool(self_arg.str, pattern_val).to_value()

  string_class.def_native_method("match?", string_match_predicate)

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
  string_class.def_native_method("include?", string_contain)

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

  proc string_contains(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let self_arg = get_positional_arg(args, 0, has_keyword_args)
    let pattern_val = get_positional_arg(args, 1, has_keyword_args)
    if self_arg.kind != VkString or pattern_val.kind != VkString:
      not_allowed("String.contains requires a string argument")
    if self_arg.str.find(pattern_val.str) >= 0: TRUE else: FALSE

  string_class.def_native_method("contains", string_contains)

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

  proc string_scan(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    string_find_all(vm, args, arg_count, has_keyword_args)

  string_class.def_native_method("scan", string_scan)

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

  proc string_sub(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    string_replace(vm, args, arg_count, has_keyword_args)

  proc string_gsub(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    string_replace_all(vm, args, arg_count, has_keyword_args)

  string_class.def_native_method("sub", string_sub)
  string_class.def_native_method("gsub", string_gsub)

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

  App.app.string_class = string_class_value
  App.app.gene_ns.ns["String".to_key()] = App.app.string_class
  App.app.global_ns.ns["String".to_key()] = App.app.string_class
