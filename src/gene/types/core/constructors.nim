## Int, String, ComplexSymbol, Array, Stream, Set, Map, Instance,
## Range, Regex, Date/DateTime/Time, Selector, SourceTrace, Gene constructors.
## Included from core.nim — shares its scope.

#################### Int ########################

# NaN boxing for integers - uses 48-bit immediates with int64 ref fallback

proc new_int_ref_value(v: int64): Value {.inline.} =
  let r = new_ref(VkInt)
  r.int_data = v
  result = r.to_ref_value()

converter to_value*(v: int): Value {.inline.} =
  let i = v.int64
  if i >= SMALL_INT_MIN and i <= SMALL_INT_MAX:
    # Fits in 48 bits - use NaN boxing
    result = Value(raw: SMALL_INT_TAG or (cast[uint64](i) and PAYLOAD_MASK))
  else:
    result = new_int_ref_value(i)

converter to_value*(v: int16): Value {.inline, noSideEffect.} =
  # int16 always fits in 48 bits
  result = Value(raw: SMALL_INT_TAG or (cast[uint64](v.int64) and PAYLOAD_MASK))

converter to_value*(v: int32): Value {.inline, noSideEffect.} =
  # int32 always fits in 48 bits
  result = Value(raw: SMALL_INT_TAG or (cast[uint64](v.int64) and PAYLOAD_MASK))

converter to_value*(v: int64): Value {.inline.} =
  if v >= SMALL_INT_MIN and v <= SMALL_INT_MAX:
    # Fits in 48 bits - use NaN boxing
    result = Value(raw: SMALL_INT_TAG or (cast[uint64](v) and PAYLOAD_MASK))
  else:
    result = new_int_ref_value(v)

converter to_int*(v: Value): int64 {.inline, noSideEffect.} =
  if is_small_int(v):
    # Extract and sign-extend from 48 bits
    let raw = v.raw and PAYLOAD_MASK
    if (raw and 0x8000_0000_0000u64) != 0:
      # Negative - sign extend
      result = cast[int64](raw or 0xFFFF_0000_0000_0000u64)
    else:
      result = cast[int64](raw)
  elif (v.raw and 0xFFFF_0000_0000_0000u64) == REF_TAG:
    let r = cast[ptr Reference](v.raw and PAYLOAD_MASK)
    if not r.is_nil and r.kind == VkInt:
      result = r.int_data
    else:
      raise newException(ValueError, "Value is not an integer")
  else:
    raise newException(ValueError, "Value is not an integer")

template int64*(v: Value): int64 =
  to_int(v)

#################### String #####################

proc new_str*(s: string): ptr String =
  result = cast[ptr String](alloc0(sizeof(String)))
  result.ref_count = 1
  result.str = s

proc new_str_value*(s: string): Value =
  let str_ptr = new_str(s)
  let ptr_addr = cast[uint64](str_ptr)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "String pointer too large for NaN boxing"
  result = cast[Value](STRING_TAG or ptr_addr)

converter to_value*(v: char): Value {.inline.} =
  {.cast(gcsafe).}:
    # Encode char in special value space
    result = cast[Value](CHAR_MASK or v.ord.uint64)

proc str*(v: Value): string =
  {.cast(gcsafe).}:
    let u = cast[uint64](v)

    # Check if it's in NaN space
    if (u and NAN_MASK) == NAN_MASK:
      case u and 0xFFFF_0000_0000_0000u64:
        of STRING_TAG:
          let x = cast[ptr String](u and PAYLOAD_MASK)
          if x.is_nil:
            result = ""  # Empty string
          else:
            result = x.str

        of SYMBOL_TAG:
          let x = cast[int64](u and PAYLOAD_MASK)
          result = get_symbol(x)

        else:
          not_allowed(fmt"{v} is not a string.")
    else:
      not_allowed(fmt"{v} is not a string.")

converter to_value*(v: string): Value =
  if v.len == 0:
    return EMPTY_STRING
  else:
    let s = cast[ptr String](alloc0(sizeof(String)))
    s.ref_count = 1
    s.str = v
    let ptr_addr = cast[uint64](s)
    assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "String pointer too large for NaN boxing"
    result = cast[Value](STRING_TAG or ptr_addr)

converter to_value*(v: Rune): Value =
  let rune_value = v.ord.uint64
  if rune_value > 0xFF_FFFF:
    return cast[Value](bitor(CHAR4_MASK, rune_value))
  elif rune_value > 0xFFFF:
    return cast[Value](bitor(CHAR3_MASK, rune_value))
  elif rune_value > 0xFF:
    return cast[Value](bitor(CHAR2_MASK, rune_value))
  else:
    return cast[Value](bitor(CHAR_MASK, rune_value))

#################### ComplexSymbol ###############

proc to_complex_symbol*(parts: seq[string]): Value {.inline.} =
  let r = new_ref(VkComplexSymbol)
  r.csymbol = parts
  result = r.to_ref_value()

#################### Array #######################

proc new_array_value*(v: varargs[Value]): Value =
  let r = cast[ptr ArrayObj](alloc0(sizeof(ArrayObj)))
  r.ref_count = 1
  r.arr = @v
  let ptr_addr = cast[uint64](r)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Array pointer too large for NaN boxing"
  result = cast[Value](ARRAY_TAG or ptr_addr)

proc len*(self: Value): int =
  case self.kind
  of VkString:
    return self.str.len
  of VkArray:
    return array_data(self).len
  of VkMap:
    return map_data(self).len
  of VkSet:
    return self.ref.set.len
  of VkGene:
    return self.gene.children.len
  of VkRange:
    # Calculate range length: (end - start) / step + 1
    let start = self.ref.range_start.int64
    let endVal = self.ref.range_end.int64
    let step = if self.ref.range_step == NIL: 1 else: self.ref.range_step.int64
    if step == 0:
      return 0
    return ((endVal - start) div step) + 1
  else:
    return 0

#################### Stream ######################

proc new_stream_value*(v: varargs[Value]): Value =
  let r = new_ref(VkStream)
  r.stream = @v
  result = r.to_ref_value()

#################### Set #########################

proc new_set_value*(): Value =
  let r = new_ref(VkSet)
  result = r.to_ref_value()

#################### Map #########################

proc new_map_value*(): Value =
  let r = cast[ptr MapObj](alloc0(sizeof(MapObj)))
  r.ref_count = 1
  r.map = initTable[Key, Value]()
  let ptr_addr = cast[uint64](r)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Map pointer too large for NaN boxing"
  result = cast[Value](MAP_TAG or ptr_addr)

proc new_map_value*(map: Table[Key, Value]): Value =
  let r = cast[ptr MapObj](alloc0(sizeof(MapObj)))
  r.ref_count = 1
  r.map = map
  let ptr_addr = cast[uint64](r)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Map pointer too large for NaN boxing"
  result = cast[Value](MAP_TAG or ptr_addr)

#################### Instance ####################

proc new_instance_value*(cls: Class): Value =
  let r = cast[ptr InstanceObj](alloc0(sizeof(InstanceObj)))
  r.ref_count = 1
  r.instance_class = cls
  r.instance_props = initTable[Key, Value]()
  let ptr_addr = cast[uint64](r)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Instance pointer too large for NaN boxing"
  result = cast[Value](INSTANCE_TAG or ptr_addr)

proc new_instance_value*(cls: Class, props: Table[Key, Value]): Value =
  let r = cast[ptr InstanceObj](alloc0(sizeof(InstanceObj)))
  r.ref_count = 1
  r.instance_class = cls
  r.instance_props = props
  let ptr_addr = cast[uint64](r)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Instance pointer too large for NaN boxing"
  result = cast[Value](INSTANCE_TAG or ptr_addr)

#################### Range ######################

proc new_range_value*(start: Value, `end`: Value, step: Value): Value =
  let r = new_ref(VkRange)
  r.range_start = start
  r.range_end = `end`
  r.range_step = step
  result = r.to_ref_value()

proc new_regex_value*(pattern: string, flags: uint8 = 0'u8, replacement: string = "", has_replacement: bool = false): Value =
  let r = new_ref(VkRegex)
  r.regex_pattern = pattern
  r.regex_flags = flags
  r.regex_replacement = replacement
  r.regex_has_replacement = has_replacement
  result = r.to_ref_value()

proc new_regex_match_value*(value: string, captures: seq[string], start: int64, `end`: int64): Value =
  let r = new_ref(VkRegexMatch)
  r.regex_match_value = value
  r.regex_match_captures = captures
  r.regex_match_start = start
  r.regex_match_end = `end`
  result = r.to_ref_value()

proc new_date_value*(year: int, month: int, day: int): Value =
  let r = new_ref(VkDate)
  r.date_year = year.int16
  r.date_month = month.int8
  r.date_day = day.int8
  result = r.to_ref_value()

proc new_datetime_value*(dt: DateTime): Value =
  let r = new_ref(VkDateTime)
  r.dt_year = dt.year.int16
  r.dt_month = ord(dt.month).int8
  r.dt_day = dt.monthday.int8
  r.dt_hour = dt.hour.int8
  r.dt_minute = dt.minute.int8
  r.dt_second = dt.second.int8
  r.dt_timezone = (dt.utcOffset div 60).int16
  result = r.to_ref_value()

proc new_time_value*(hour: int, minute: int, second: int, microsecond: int = 0): Value =
  let r = new_ref(VkTime)
  r.time_hour = hour.int8
  r.time_minute = minute.int8
  r.time_second = second.int8
  r.time_microsecond = microsecond.int32
  result = r.to_ref_value()

proc new_selector_value*(segments: openArray[Value]): Value =
  if segments.len == 0:
    not_allowed("Selector requires at least one segment")

  let r = new_ref(VkSelector)
  r.selector_path = @[]

  var pattern_parts: seq[string] = @[]
  for seg in segments:
    case seg.kind:
      of VkString, VkSymbol:
        pattern_parts.add(seg.str)
        r.selector_path.add(seg)
      of VkInt:
        pattern_parts.add($seg.int64)
        r.selector_path.add(seg)
      of VkFunction, VkNativeFn, VkBlock, VkBoundMethod, VkNativeMethod:
        pattern_parts.add("<" & $seg.kind & ">")
        r.selector_path.add(seg)
      else:
        not_allowed("Invalid selector segment: " & $seg.kind)

  r.selector_pattern = pattern_parts.join("/")
  result = r.to_ref_value()

#################### SourceTrace ##################

proc new_source_trace*(filename: string, line, column: int): SourceTrace =
  SourceTrace(
    filename: filename,
    line: line,
    column: column,
    children: @[],
    child_index: -1,
  )

proc attach_child*(parent: SourceTrace, child: SourceTrace) =
  if parent.is_nil or child.is_nil:
    return
  child.parent = parent
  child.child_index = parent.children.len
  parent.children.add(child)

proc trace_location*(trace: SourceTrace): string =
  if trace.is_nil:
    return ""
  if trace.filename.len > 0:
    result = trace.filename & ":" & $trace.line & ":" & $trace.column
  else:
    result = $trace.line & ":" & $trace.column

#################### Gene ########################

proc to_gene_value*(v: ptr Gene): Value {.inline.} =
  v.ref_count.inc()
  # Ensure pointer fits in 48 bits
  let ptr_addr = cast[uint64](v)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Gene pointer too large for NaN boxing"
  result = cast[Value](GENE_TAG or ptr_addr)

proc `$`*(self: ptr Gene): string =
  result = "(" & $self.type
  for k, v in self.props:
    result &= " ^" & get_symbol(k.symbol_index) & " " & $v
  for child in self.children:
    result &= " " & $child
  result &= ")"

proc new_gene*(): ptr Gene =
  result = cast[ptr Gene](alloc0(sizeof(Gene)))
  result.ref_count = 1
  result.type = NIL
  result.trace = nil
  result.props = Table[Key, Value]()
  result.children = @[]

proc new_gene*(`type`: Value): ptr Gene =
  result = cast[ptr Gene](alloc0(sizeof(Gene)))
  result.ref_count = 1
  result.type = `type`
  result.trace = nil
  result.props = Table[Key, Value]()
  result.children = @[]

proc new_gene_value*(): Value {.inline.} =
  new_gene().to_gene_value()

proc new_gene_value*(`type`: Value): Value {.inline.} =
  new_gene(`type`).to_gene_value()

# proc args_are_literal(self: ptr Gene): bool =
#   for k, v in self.props:
#     if not v.is_literal():
#       return false
#   for v in self.children:
#     if not v.is_literal():
#       return false
#   true
