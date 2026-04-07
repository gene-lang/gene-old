## Common (Key/Id), Reference (retain, release, array_ptr, map_ptr, instance_ptr,
## new_ref), Value (==, kind, is_literal, $, str_no_quotes, [], size).
## Included from core.nim — shares its scope.

#################### Common ######################

template `==`*(a, b: Key): bool =
  cast[int64](a) == cast[int64](b)

template hash*(v: Key): Hash =
  cast[Hash](v)

template `==`*(a, b: Id): bool =
  cast[int64](a) == cast[int64](b)

template hash*(v: Id): Hash =
  cast[Hash](v)

proc todo*() =
  raise new_exception(type_defs.Exception, "TODO")

proc todo*(message: string) =
  raise new_exception(type_defs.Exception, "TODO: " & message)

proc not_allowed*(message: string) =
  raise new_exception(type_defs.Exception, message)

proc not_allowed*() =
  not_allowed("Error: should not arrive here.")

proc to_binstr*(v: int64): string =
  re.replacef(fmt"{v: 065b}", re.re"([01]{8})", "$1 ")

proc new_id*(): Id =
  cast[Id](rand(BIGGEST_INT))

converter to_value*(k: Key): Value {.inline.} =
  cast[Value](k)

#################### Reference ###################

# Ownership model:
# - new_ref/new_gene/new_str_value/new_array_value/new_map_value/new_instance_value
#   return ref_count = 1. Boxing to Value does NOT retain; stack ops are ref-neutral.
#   Store outside the stack? Call retain/release.
# - release() destroys Reference/Gene/String/Array/Map/Instance when ref_count reaches 0.
# - Scope lifetime is owned by VM instructions (IkScopeStart/IkScopeEnd); frames borrow/own
#   per compiler emission. Frames are pooled via Frame.free().
# Manual ref counting is used instead of Nim ARC/ORC for Value-backed types.
# Map, Array, and Instance use dedicated NaN-tagged objects rather than Reference.

# Manual reference counting for Values
proc retain*(v: Value) {.inline.} =
  {.push checks: off.}
  let u = cast[uint64](v)
  if (u and NAN_MASK) == NAN_MASK:  # In NaN space
    case u and 0xFFFF_0000_0000_0000u64:
      of REF_TAG:
        let x = cast[ptr Reference](u and PAYLOAD_MASK)
        x.ref_count.inc()
      of ARRAY_TAG:
        let x = cast[ptr ArrayObj](u and PAYLOAD_MASK)
        x.ref_count.inc()
      of MAP_TAG:
        let x = cast[ptr MapObj](u and PAYLOAD_MASK)
        x.ref_count.inc()
      of INSTANCE_TAG:
        let x = cast[ptr InstanceObj](u and PAYLOAD_MASK)
        x.ref_count.inc()
      of GENE_TAG:
        let x = cast[ptr Gene](u and PAYLOAD_MASK)
        x.ref_count.inc()
      of STRING_TAG:
        let x = cast[ptr String](u and PAYLOAD_MASK)
        if not x.is_nil:
          x.ref_count.inc()
      else:
        discard  # No ref counting for other types
  {.pop.}

proc release*(v: Value) {.inline.} =
  {.push checks: off.}
  let u = cast[uint64](v)
  if (u and NAN_MASK) == NAN_MASK:  # In NaN space
    case u and 0xFFFF_0000_0000_0000u64:
      of REF_TAG:
        let x = cast[ptr Reference](u and PAYLOAD_MASK)
        if x.ref_count == 1:
          if x.kind == VkFunction and x.fn != nil and x.fn.native_descriptors.len > 0:
            for desc in x.fn.native_descriptors:
              release(desc.callable)
            x.fn.native_descriptors = @[]
          reset(x[])
          dealloc(x)
        else:
          x.ref_count.dec()
      of ARRAY_TAG:
        let x = cast[ptr ArrayObj](u and PAYLOAD_MASK)
        if x.ref_count == 1:
          dealloc(x)
        else:
          x.ref_count.dec()
      of MAP_TAG:
        let x = cast[ptr MapObj](u and PAYLOAD_MASK)
        if x.ref_count == 1:
          dealloc(x)
        else:
          x.ref_count.dec()
      of INSTANCE_TAG:
        let x = cast[ptr InstanceObj](u and PAYLOAD_MASK)
        if x.ref_count == 1:
          dealloc(x)
        else:
          x.ref_count.dec()
      of GENE_TAG:
        let x = cast[ptr Gene](u and PAYLOAD_MASK)
        if x.ref_count == 1:
          dealloc(x)
        else:
          x.ref_count.dec()
      of STRING_TAG:
        let x = cast[ptr String](u and PAYLOAD_MASK)
        if not x.is_nil:
          if x.ref_count == 1:
            dealloc(x)
          else:
            x.ref_count.dec()
      else:
        discard  # No ref counting for other types
  {.pop.}

proc array_ptr*(v: Value): ptr ArrayObj {.inline.} =
  let u = cast[uint64](v)
  if (u and 0xFFFF_0000_0000_0000u64) != ARRAY_TAG:
    raise newException(ValueError, "Value is not an array")
  cast[ptr ArrayObj](u and PAYLOAD_MASK)

template array_data*(v: Value): var seq[Value] =
  array_ptr(v).arr

proc array_is_frozen*(v: Value): bool {.inline, gcsafe, noSideEffect.} =
  let u = cast[uint64](v)
  ((u and 0xFFFF_0000_0000_0000u64) == ARRAY_TAG) and cast[ptr ArrayObj](u and PAYLOAD_MASK).frozen

proc ensure_mutable_array*(v: Value, op_name = "mutate"): void {.inline.} =
  if array_is_frozen(v):
    not_allowed("Cannot " & op_name & " immutable array")

proc map_ptr*(v: Value): ptr MapObj {.inline.} =
  let u = cast[uint64](v)
  if (u and 0xFFFF_0000_0000_0000u64) != MAP_TAG:
    raise newException(ValueError, "Value is not a map")
  cast[ptr MapObj](u and PAYLOAD_MASK)

template map_data*(v: Value): var Table[Key, Value] =
  map_ptr(v).map

proc map_is_frozen*(v: Value): bool {.inline, gcsafe, noSideEffect.} =
  let u = cast[uint64](v)
  ((u and 0xFFFF_0000_0000_0000u64) == MAP_TAG) and cast[ptr MapObj](u and PAYLOAD_MASK).frozen

proc ensure_mutable_map*(v: Value, op_name = "mutate"): void {.inline.} =
  if map_is_frozen(v):
    not_allowed("Cannot " & op_name & " immutable map")

proc gene_is_frozen*(v: Value): bool {.inline, gcsafe, noSideEffect.} =
  let u = cast[uint64](v)
  ((u and 0xFFFF_0000_0000_0000u64) == GENE_TAG) and cast[ptr Gene](u and PAYLOAD_MASK).frozen

proc ensure_mutable_gene*(v: Value, op_name = "mutate"): void {.inline.} =
  if gene_is_frozen(v):
    not_allowed("Cannot " & op_name & " immutable gene")

proc instance_ptr*(v: Value): ptr InstanceObj {.inline.} =
  let u = cast[uint64](v)
  when defined(release):
    # Fast path in release builds: trust callers that the tag is correct.
    cast[ptr InstanceObj](u and PAYLOAD_MASK)
  else:
    if (u and 0xFFFF_0000_0000_0000u64) != INSTANCE_TAG:
      raise newException(ValueError, "Value is not an instance")
    cast[ptr InstanceObj](u and PAYLOAD_MASK)

template instance_class*(v: Value): var Class =
  instance_ptr(v).instance_class

template instance_props*(v: Value): var Table[Key, Value] =
  instance_ptr(v).instance_props

proc `==`*(a, b: ptr Reference): bool =
  if a.is_nil:
    return b.is_nil

  if b.is_nil:
    return false

  if a.kind != b.kind:
    return false

  case a.kind:
    of VkInt:
      return a.int_data == b.int_data
    of VkSet:
      let items1 = a.set_items
      let items2 = b.set_items
      if items1.len != items2.len:
        return false
      for item1 in items1:
        var found = false
        for item2 in items2:
          if item1 == item2:
            found = true
            break
        if not found:
          return false
      return true
    of VkComplexSymbol:
      return a.csymbol == b.csymbol
    else:
      # Fallback to pointer identity for other reference types
      return cast[pointer](a) == cast[pointer](b)

proc `$`*(self: ptr Reference): string =
  $self.kind

proc new_ref*(kind: ValueKind): ptr Reference {.inline.} =
  result = cast[ptr Reference](alloc0(sizeof(Reference)))
  result.ref_count = 1
  # Write discriminant with layout-safe offset/size (works on 32-bit and 64-bit).
  var k = kind
  let kind_offset = cast[uint](offsetOf(Reference, kind))
  copy_mem(cast[pointer](cast[uint](result) + kind_offset), addr k, sizeof(ValueKind))

proc `ref`*(v: Value): ptr Reference {.inline.} =
  let u = cast[uint64](v)
  if (u and 0xFFFF_0000_0000_0000u64) == REF_TAG:
    cast[ptr Reference](u and PAYLOAD_MASK)
  else:
    raise newException(ValueError, "Value is not a reference")

proc to_ref_value*(v: ptr Reference): Value {.inline.} =
  v.ref_count.inc()
  # Ensure pointer fits in 48 bits
  let ptr_addr = cast[uint64](v)
  assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Reference pointer too large for NaN boxing"
  result = cast[Value](REF_TAG or ptr_addr)

template hash_map_items*(v: Value): var seq[Value] =
  `ref`(v).hash_map_items

template hash_map_buckets*(v: Value): var OrderedTable[Hash, seq[int]] =
  `ref`(v).hash_map_buckets

template hash_set_items*(v: Value): var seq[Value] =
  `ref`(v).set_items

template hash_set_buckets*(v: Value): var OrderedTable[Hash, seq[int]] =
  `ref`(v).set_buckets

proc hash_map_is_frozen*(v: Value): bool {.inline, gcsafe, noSideEffect.} =
  let u = cast[uint64](v)
  if (u and 0xFFFF_0000_0000_0000u64) != REF_TAG:
    return false
  let r = cast[ptr Reference](u and PAYLOAD_MASK)
  r != nil and r.kind == VkHashMap and r.hash_map_frozen

proc ensure_mutable_hash_map*(v: Value, op_name = "mutate"): void {.inline, gcsafe.} =
  if hash_map_is_frozen(v):
    not_allowed("Cannot " & op_name & " immutable hash map")

#################### Value ######################

# Forward declaration
converter to_int*(v: Value): int64 {.inline, noSideEffect.}

proc `==`*(a, b: Value): bool {.gcsafe, noSideEffect.} =
  if cast[uint64](a) == cast[uint64](b):
    return true

  {.cast(noSideEffect).}:
    {.cast(gcsafe).}:
      let u1 = cast[uint64](a)
      let u2 = cast[uint64](b)

      # Check if both are strings and compare them
      let tag1 = u1 and 0xFFFF_0000_0000_0000u64
      let tag2 = u2 and 0xFFFF_0000_0000_0000u64

      if tag1 == REF_TAG and a.ref.kind == VkCustom and a.ref.custom_data != nil and
         a.ref.custom_data.materialize_hook != nil:
        return a.ref.custom_data.materialize_hook(a.ref.custom_data) == b
      if tag2 == REF_TAG and b.ref.kind == VkCustom and b.ref.custom_data != nil and
         b.ref.custom_data.materialize_hook != nil:
        return a == b.ref.custom_data.materialize_hook(b.ref.custom_data)

      # Int values can be represented as either 48-bit immediates or refs.
      let a_is_int = tag1 == SMALL_INT_TAG or (tag1 == REF_TAG and a.ref.kind == VkInt)
      let b_is_int = tag2 == SMALL_INT_TAG or (tag2 == REF_TAG and b.ref.kind == VkInt)
      if a_is_int and b_is_int:
        return a.to_int() == b.to_int()

      # Both strings - compare their content
      if tag1 == STRING_TAG and tag2 == STRING_TAG:
        let str1 = cast[ptr String](u1 and PAYLOAD_MASK)
        let str2 = cast[ptr String](u2 and PAYLOAD_MASK)

        # Handle empty string case
        if str1.is_nil and str2.is_nil:
          return true
        elif str1.is_nil or str2.is_nil:
          return false
        else:
          return str1.str == str2.str
      # Maps compare structurally
      elif tag1 == MAP_TAG and tag2 == MAP_TAG:
        let map1 = map_ptr(a).map
        let map2 = map_ptr(b).map
        if map1.len != map2.len:
          return false
        for k, v in map1:
          let other = map2.getOrDefault(k, NOT_FOUND)
          if other == NOT_FOUND or v != other:
            return false
        return true
      elif tag1 == REF_TAG and tag2 == REF_TAG and a.ref.kind == VkHashMap and b.ref.kind == VkHashMap:
        let items1 = a.ref.hash_map_items
        let items2 = b.ref.hash_map_items
        if items1.len != items2.len:
          return false
        var i = 0
        while i < items1.len:
          if items1[i] != items2[i] or items1[i + 1] != items2[i + 1]:
            return false
          i += 2
        return true
      elif tag1 == REF_TAG and tag2 == REF_TAG and a.ref.kind == VkSet and b.ref.kind == VkSet:
        let items1 = a.ref.set_items
        let items2 = b.ref.set_items
        if items1.len != items2.len:
          return false
        for item1 in items1:
          var found = false
          for item2 in items2:
            if item1 == item2:
              found = true
              break
          if not found:
            return false
        return true
      # Arrays compare structurally
      elif tag1 == ARRAY_TAG and tag2 == ARRAY_TAG:
        let arr1 = array_ptr(a).arr
        let arr2 = array_ptr(b).arr
        if arr1.len != arr2.len:
          return false
        for i in 0 ..< arr1.len:
          if arr1[i] != arr2[i]:
            return false
        return true
      # Instances compare by identity
      elif tag1 == INSTANCE_TAG and tag2 == INSTANCE_TAG:
        return (u1 and PAYLOAD_MASK) == (u2 and PAYLOAD_MASK)
      # Date/time structural comparison
      elif tag1 == REF_TAG and tag2 == REF_TAG and a.ref.kind == b.ref.kind:
        case a.ref.kind:
          of VkDate:
            return a.ref.date_year == b.ref.date_year and
                   a.ref.date_month == b.ref.date_month and
                   a.ref.date_day == b.ref.date_day
          of VkDateTime:
            return a.ref.dt_year == b.ref.dt_year and
                   a.ref.dt_month == b.ref.dt_month and
                   a.ref.dt_day == b.ref.dt_day and
                   a.ref.dt_hour == b.ref.dt_hour and
                   a.ref.dt_minute == b.ref.dt_minute and
                   a.ref.dt_second == b.ref.dt_second and
                   a.ref.dt_microsecond == b.ref.dt_microsecond and
                   a.ref.dt_timezone == b.ref.dt_timezone and
                   a.ref.dt_tz_name == b.ref.dt_tz_name
          of VkTime:
            return a.ref.time_hour == b.ref.time_hour and
                   a.ref.time_minute == b.ref.time_minute and
                   a.ref.time_second == b.ref.time_second and
                   a.ref.time_microsecond == b.ref.time_microsecond and
                   a.ref.time_tz_offset == b.ref.time_tz_offset and
                   a.ref.time_tz_name == b.ref.time_tz_name
          else:
            return a.ref == b.ref
      # Only references can be equal with different bit patterns
      elif tag1 == REF_TAG and tag2 == REF_TAG:
        return a.ref == b.ref

  # Default to false
  return false

proc hash*(v: Value): Hash {.inline.} =
  if v.kind == VkInt:
    return hash(v.to_int())
  return hash(cast[uint64](v))

proc is_float*(v: Value): bool {.inline, noSideEffect.} =
  let u = cast[uint64](v)
  # A value is a float if it's NOT in our NaN boxing space (0xFFF0-0xFFFF prefix)
  # The only exceptions are actual float NaN/infinity values
  if (u and NAN_MASK) != NAN_MASK:
    return true  # Regular float
  # Check for positive/negative infinity which are valid floats
  if (u and 0x7FFF_FFFF_FFFF_FFFF'u64) == 0x7FF0_0000_0000_0000'u64:
    return true  # ±infinity (0x7FF0000000000000 or 0xFFF0000000000000)
  # Everything else in NaN space is not a float
  return false

proc is_small_int*(v: Value): bool {.inline, noSideEffect.} =
  (cast[uint64](v) and 0xFFFF_0000_0000_0000u64) == SMALL_INT_TAG

proc kind_slow(v: Value, u: uint64, tag: uint64): ValueKind {.noinline.} =
  case tag:
    of POINTER_TAG:
      return VkPointer
    of SPECIAL_TAG:
      # Special values
      case u:
        of NIL.raw:
          return VkNil
        of TRUE.raw, FALSE.raw:
          return VkBool
        of VOID.raw:
          return VkVoid
        of PLACEHOLDER.raw:
          return VkPlaceholder
        else:
          # Check for character values
          let char_type = u and 0xFFFF_FFFF_0000_0000u64
          if char_type == (CHAR_MASK and 0xFFFF_FFFF_0000_0000u64) or
             char_type == (CHAR2_MASK and 0xFFFF_FFFF_0000_0000u64) or
             char_type == (CHAR3_MASK and 0xFFFF_FFFF_0000_0000u64) or
             char_type == (CHAR4_MASK and 0xFFFF_FFFF_0000_0000u64):
            return VkChar
          else:
            todo($u)
    else:
      todo($u)

proc kind*(v: Value): ValueKind {.inline.} =
  {.cast(gcsafe).}:
    let u = cast[uint64](v)

    # Fast path: Check if it's a float first (most common case)
    if (u and NAN_MASK) != NAN_MASK:
      return VkFloat

    # Fast path: Check most common NaN-boxed types with single comparisons
    let tag = u and 0xFFFF_0000_0000_0000u64
  case tag:
    of SMALL_INT_TAG:
      return VkInt
    of REF_TAG:
      return v.ref.kind  # Single pointer dereference
    of ARRAY_TAG:
      return VkArray
    of MAP_TAG:
      return VkMap
    of INSTANCE_TAG:
      return VkInstance
    of SYMBOL_TAG:
      return VkSymbol
    of STRING_TAG:
      return VkString
    of GENE_TAG:
      return VkGene
    else:
      # Uncommon cases - delegate to separate function
      return kind_slow(v, u, tag)

proc is_literal*(self: Value): bool =
  {.cast(gcsafe).}:
    let u = cast[uint64](self)

    # Floats and integers are literals
    if not ((u and NAN_MASK) == NAN_MASK):
      return true  # Regular float

    # Check NaN-boxed values
    case u and 0xFFFF_0000_0000_0000u64:
      of ARRAY_TAG:
        for v in array_data(self):
          if not is_literal(v):
            return false
        return true
      of MAP_TAG:
        for v in map_data(self).values:
          if not is_literal(v):
            return false
        return true
      of INSTANCE_TAG:
        result = false
      of SMALL_INT_TAG, STRING_TAG:
        result = true
      of SPECIAL_TAG:
        # nil, true, false, void, etc. are literals
        result = true
      of SYMBOL_TAG:
        result = false
      of POINTER_TAG:
        result = false
      of REF_TAG:
        let r = self.ref
        case r.kind:
          of VkInt, VkSelector, VkRegex:
            return true
          of VkHashMap:
            for item in r.hash_map_items:
              if not is_literal(item):
                return false
            return true
          else:
            result = false
      of GENE_TAG:
        result = false
      else:
        result = false

proc escape_regex_segment(seg: string): string {.inline.} =
  result = ""
  for ch in seg:
    case ch
    of '\\':
      result.add("\\\\")
    of '/':
      result.add("\\/")
    else:
      result.add(ch)

proc regex_flags_to_string(flags: uint8): string {.inline.} =
  result = ""
  if (flags and REGEX_FLAG_IGNORE_CASE) != 0:
    result.add('i')
  if (flags and REGEX_FLAG_MULTILINE) != 0:
    result.add('m')

proc format_regex_literal(self: Value): string =
  result = "#/" & escape_regex_segment(self.ref.regex_pattern) & "/"
  if self.ref.regex_has_replacement:
    result &= escape_regex_segment(self.ref.regex_replacement) & "/"
  result &= regex_flags_to_string(self.ref.regex_flags)

proc pad2(v: int): string {.inline.} =
  if v < 10: "0" & $v else: $v

proc pad4(v: int): string {.inline.} =
  if v < 10: "000" & $v
  elif v < 100: "00" & $v
  elif v < 1000: "0" & $v
  else: $v

proc format_microseconds(us: int32): string =
  if us == 0: return ""
  var s = $us
  while s.len < 6: s = "0" & s
  # Trim trailing zeros
  var last = s.len - 1
  while last > 0 and s[last] == '0': dec(last)
  "." & s[0..last]

proc format_tz_offset(offset_minutes: int16): string =
  if offset_minutes == 0: return "Z"
  let sign = if offset_minutes < 0: "-" else: "+"
  let abs_min = abs(offset_minutes.int)
  let h = abs_min div 60
  let m = abs_min mod 60
  sign & pad2(h) & ":" & pad2(m)

proc format_date(r: ptr Reference): string =
  pad4(r.date_year.int) & "-" & pad2(r.date_month.int) & "-" & pad2(r.date_day.int)

proc format_datetime(r: ptr Reference): string =
  result = pad4(r.dt_year.int) & "-" & pad2(r.dt_month.int) & "-" & pad2(r.dt_day.int) &
           "T" & pad2(r.dt_hour.int) & ":" & pad2(r.dt_minute.int)
  if r.dt_second != 0 or r.dt_microsecond != 0 or r.dt_timezone != 0 or r.dt_tz_name.len > 0:
    result &= ":" & pad2(r.dt_second.int)
  result &= format_microseconds(r.dt_microsecond)
  # Timezone: only show if tz_name is set (includes "UTC" for Z) or offset is non-zero
  if r.dt_tz_name == "UTC" and r.dt_timezone == 0:
    result &= "Z"
  elif r.dt_timezone != 0:
    result &= format_tz_offset(r.dt_timezone)
    if r.dt_tz_name.len > 0 and r.dt_tz_name != "UTC":
      result &= "[" & r.dt_tz_name & "]"
  elif r.dt_tz_name.len > 0:
    # Has zone name but zero offset (unusual but valid)
    result &= "Z[" & r.dt_tz_name & "]"

proc format_time(r: ptr Reference): string =
  result = pad2(r.time_hour.int) & ":" & pad2(r.time_minute.int)
  if r.time_second != 0 or r.time_microsecond != 0 or r.time_tz_offset != 0 or r.time_tz_name.len > 0:
    result &= ":" & pad2(r.time_second.int)
  result &= format_microseconds(r.time_microsecond)
  if r.time_tz_name == "UTC" and r.time_tz_offset == 0:
    result &= "Z"
  elif r.time_tz_name.len > 0 and r.time_tz_name != "UTC":
    if r.time_tz_offset != 0:
      result &= format_tz_offset(r.time_tz_offset)
    result &= "[" & r.time_tz_name & "]"
  elif r.time_tz_offset != 0:
    result &= format_tz_offset(r.time_tz_offset)

proc str_no_quotes*(self: Value): string {.gcsafe.} =
  {.cast(gcsafe).}:
    case self.kind:
      of VkNil:
        result = "nil"
      of VkVoid:
        result = "void"
      of VkPlaceholder:
        result = "_"
      of VkBool:
        result = $(self == TRUE)
      of VkInt:
        result = $(self.to_int())
      of VkFloat:
        result = $(cast[float64](self))
      of VkChar:
        # Check if it's the special NOT_FOUND value
        if self == NOT_FOUND:
          result = "not_found"
        else:
          result = $cast[char](cast[int64](self) and 0xFF)
      of VkString:
        result = $self.str
      of VkSymbol:
        result = $self.str
      of VkComplexSymbol:
        result = self.ref.csymbol.join("/")
      of VkRatio:
        result = $self.ref.ratio_num & "/" & $self.ref.ratio_denom
      of VkArray:
        result = if array_is_frozen(self): "#[" else: "["
        for i, v in array_data(self):
          if i > 0:
            result &= " "
          result &= v.str_no_quotes()
        result &= "]"
      of VkSet:
        result = "(HashSet"
        for item in self.ref.set_items:
          result &= " " & item.str_no_quotes()
        result &= ")"
      of VkMap:
        result = if map_is_frozen(self): "#{" else: "{"
        var first = true
        for k, v in map_data(self):
          if not first:
            result &= " "
          # Key is a symbol value cast to int64, need to extract the symbol index
          let symbol_value = cast[Value](k)
          let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
          result &= "^" & get_symbol(symbol_index.int) & " " & v.str_no_quotes()
          first = false
        result &= "}"
      of VkHashMap:
        result = if hash_map_is_frozen(self): "#{{" else: "{{"
        var first = true
        var i = 0
        while i < self.ref.hash_map_items.len:
          if not first:
            result &= " "
          result &= self.ref.hash_map_items[i].str_no_quotes()
          if i + 1 < self.ref.hash_map_items.len:
            result &= " " & self.ref.hash_map_items[i + 1].str_no_quotes()
          first = false
          i += 2
        result &= "}}"
      of VkSelector:
        result = "@(" & self.ref.selector_pattern & ")"
      of VkGene:
        result = $self.gene
      of VkRange:
        result = $self.ref.range_start & ".." & $self.ref.range_end
        if self.ref.range_step != NIL:
          result &= " step " & $self.ref.range_step
      of VkRegex:
        result = format_regex_literal(self)
      of VkDate:
        result = format_date(self.ref)
      of VkDateTime:
        result = format_datetime(self.ref)
      of VkTime:
        result = format_time(self.ref)
      of VkFuture:
        result = "<Future " & $self.ref.future.state & ">"
      of VkEnum:
        result = self.ref.enum_def.name
      of VkEnumMember:
        result = self.ref.enum_member.parent.ref.enum_def.name & "/" & self.ref.enum_member.name
      of VkCustom:
        if self.ref != nil and self.ref.custom_data != nil and self.ref.custom_data.materialize_hook != nil:
          result = self.ref.custom_data.materialize_hook(self.ref.custom_data).str_no_quotes()
        elif self.ref != nil and self.ref.custom_data != nil and (self.ref.custom_data of RuntimeTypeValueData):
          let payload = RuntimeTypeValueData(self.ref.custom_data)
          result = type_desc_to_string(payload.runtime_type.type_id, payload.type_descs)
        else:
          result = $self.kind
      else:
        result = $self.kind

proc `$`*(self: Value): string {.gcsafe.} =
  {.cast(gcsafe).}:
    case self.kind:
      of VkNil:
        result = "nil"
      of VkVoid:
        result = "void"
      of VkPlaceholder:
        result = "_"
      of VkBool:
        result = $(self == TRUE)
      of VkInt:
        result = $(to_int(self))
      of VkFloat:
        result = $(cast[float64](self))
      of VkChar:
        # Check if it's the special NOT_FOUND value
        if self == NOT_FOUND:
          result = "not_found"
        else:
          result = "'" & $cast[char](cast[int64](self) and 0xFF) & "'"
      of VkString:
        result = "\"" & $self.str & "\""
      of VkSymbol:
        result = $self.str
      of VkComplexSymbol:
        result = self.ref.csymbol.join("/")
      of VkRatio:
        result = $self.ref.ratio_num & "/" & $self.ref.ratio_denom
      of VkArray:
        result = if array_is_frozen(self): "#[" else: "["
        for i, v in array_data(self):
          if i > 0:
            result &= " "
          result &= $v
        result &= "]"
      of VkSet:
        result = "(HashSet"
        for item in self.ref.set_items:
          result &= " " & $item
        result &= ")"
      of VkMap:
        result = if map_is_frozen(self): "#{" else: "{"
        var first = true
        for k, v in map_data(self):
          if not first:
            result &= " "
          # Key is a symbol value cast to int64, need to extract the symbol index
          let symbol_value = cast[Value](k)
          let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
          result &= "^" & get_symbol(symbol_index.int) & " " & $v
          first = false
        result &= "}"
      of VkHashMap:
        result = if hash_map_is_frozen(self): "#{{" else: "{{"
        var first = true
        var i = 0
        while i < self.ref.hash_map_items.len:
          if not first:
            result &= " "
          result &= $self.ref.hash_map_items[i]
          if i + 1 < self.ref.hash_map_items.len:
            result &= " " & $self.ref.hash_map_items[i + 1]
          first = false
          i += 2
        result &= "}}"
      of VkSelector:
        result = "@(" & self.ref.selector_pattern & ")"
      of VkGene:
        result = $self.gene
      of VkRange:
        result = $self.ref.range_start & ".." & $self.ref.range_end
        if self.ref.range_step != NIL:
          result &= " step " & $self.ref.range_step
      of VkRegex:
        result = format_regex_literal(self)
      of VkDate:
        result = format_date(self.ref)
      of VkDateTime:
        result = format_datetime(self.ref)
      of VkTime:
        result = format_time(self.ref)
      of VkFuture:
        result = "<Future " & $self.ref.future.state & ">"
      of VkEnum:
        result = self.ref.enum_def.name
      of VkEnumMember:
        result = self.ref.enum_member.parent.ref.enum_def.name & "/" & self.ref.enum_member.name
      of VkCustom:
        if self.ref != nil and self.ref.custom_data != nil and self.ref.custom_data.materialize_hook != nil:
          result = $self.ref.custom_data.materialize_hook(self.ref.custom_data)
        elif self.ref != nil and self.ref.custom_data != nil and (self.ref.custom_data of RuntimeTypeValueData):
          let payload = RuntimeTypeValueData(self.ref.custom_data)
          result = type_desc_to_string(payload.runtime_type.type_id, payload.type_descs)
        else:
          result = $self.kind
      of VkInterface:
        result = "<Interface " & self.ref.gene_interface.name & ">"
      of VkAdapter:
        result = "<Adapter:" & self.ref.adapter.gene_interface.name & " " & $self.ref.adapter.inner & ">"
      of VkAdapterInternal:
        result = "<AdapterInternal>"
      else:
        result = $self.kind

proc is_nil*(v: Value): bool {.inline.} =
  v == NIL

proc to_float*(v: Value): float64 {.inline.} =
  if is_float(v):
    return cast[float64](v)
  elif v.kind == VkInt:
    # Convert integer to float
    return to_int(v).float64
  else:
    raise newException(ValueError, "Value is not a number")

template float*(v: Value): float64 =
  to_float(v)

template float64*(v: Value): float64 =
  to_float(v)

converter to_value*(v: float64): Value {.inline.} =
  # In NaN boxing, floats are stored directly
  # Only NaN-boxed values (0xFFF0-0xFFFF prefix) are non-floats
  result = cast[Value](v)

converter to_bool*(v: Value): bool {.inline.} =
  not (v == FALSE or v == NIL or v == VOID)

converter to_value*(v: bool): Value {.inline.} =
  if v:
    return TRUE
  else:
    return FALSE

proc to_pointer*(v: Value): pointer {.inline.} =
  if (cast[uint64](v) and 0xFFFF_0000_0000_0000u64) == POINTER_TAG:
    result = cast[pointer](cast[uint64](v) and PAYLOAD_MASK)
  else:
    raise newException(ValueError, "Value is not a pointer")

converter to_value*(v: pointer): Value {.inline.} =
  if v.is_nil:
    return NIL
  else:
    # Ensure pointer fits in 48 bits (true on x86-64, ARM64)
    let ptr_addr = cast[uint64](v)
    assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "Pointer too large for NaN boxing"
    result = cast[Value](POINTER_TAG or ptr_addr)

# Applicable to array, vector, string, symbol, gene etc
proc `[]`*(self: Value, i: int): Value =
  let u = cast[uint64](self)

  # Check for special values first
  if u == cast[uint64](NIL):
    return NIL

  # Check if it's in NaN space
  if (u and NAN_MASK) == NAN_MASK:
    let tag = u and 0xFFFF_0000_0000_0000u64
    case tag:
      of ARRAY_TAG:
        let arr = array_data(self)
        if i >= 0 and i < arr.len:
          return arr[i]
        else:
          return NIL
      of REF_TAG:
        let r = self.ref
        case r.kind:
          of VkCustom:
            if r.custom_data != nil and r.custom_data.materialize_hook != nil:
              return r.custom_data.materialize_hook(r.custom_data)[i]
            todo($r.kind)
          of VkString:
            var j = 0
            for rune in r.str.runes:
              if i == j:
                return rune
              j.inc()
            return NIL
          of VkBytes:
            if i >= r.bytes_data.len:
              return NIL
            else:
              return Value(raw: SMALL_INT_TAG or cast[uint64](r.bytes_data[i]))
          of VkRange:
            # Calculate the i-th element in the range
            let start_int = r.range_start.int64
            let step_int = if r.range_step == NIL: 1.int64 else: r.range_step.int64
            let end_int = r.range_end.int64

            let value = start_int + (i.int64 * step_int)

            # Check if the value is within the range bounds
            if step_int > 0:
              if value >= start_int and value < end_int:
                return Value(raw: SMALL_INT_TAG or (cast[uint64](value) and PAYLOAD_MASK))
              else:
                return NIL
            else:  # step_int < 0
              if value <= start_int and value > end_int:
                return Value(raw: SMALL_INT_TAG or (cast[uint64](value) and PAYLOAD_MASK))
              else:
                return NIL
          else:
            todo($r.kind)
      of GENE_TAG:
        let g = self.gene
        if i >= g.children.len:
          return NIL
        else:
          return g.children[i]
      of STRING_TAG:
        var j = 0
        for rune in self.str().runes:
          if i == j:
            return rune
          j.inc()
        return NIL
      of SYMBOL_TAG:
        var j = 0
        for rune in self.str().runes:
          if i == j:
            return rune
          j.inc()
        return NIL
      else:
        todo($u)
  else:
    # Not in NaN space - must be a float
    todo($u)

# Applicable to array, vector, string, symbol, gene etc
proc size*(self: Value): int =
  let u = cast[uint64](self)

  # Check for special values first
  if u == cast[uint64](NIL):
    return 0

  # Check if it's in NaN space
  if (u and NAN_MASK) == NAN_MASK:
    let tag = u and 0xFFFF_0000_0000_0000u64
    case tag:
      of ARRAY_TAG:
        return array_data(self).len
      of REF_TAG:
        let r = self.ref
        case r.kind:
          of VkCustom:
            if r.custom_data != nil and r.custom_data.materialize_hook != nil:
              return r.custom_data.materialize_hook(r.custom_data).size()
            return 0
          of VkHashMap:
            return r.hash_map_items.len div 2
          of VkSet:
            return r.set_items.len
          of VkMap:
            return r.map.len
          of VkString:
            return r.str.to_runes().len
          of VkBytes:
            return r.bytes_data.len
          of VkRange:
            # Calculate range size based on start, end, and step
            let start_int = r.range_start.int64
            let end_int = r.range_end.int64
            let step_int = if r.range_step == NIL: 1.int64 else: r.range_step.int64
            if step_int == 0:
              return 0
            elif step_int > 0:
              if start_int <= end_int:
                return int((end_int - start_int) div step_int) + 1
              else:
                return 0
            else:  # step_int < 0
              if start_int >= end_int:
                return int((start_int - end_int) div (-step_int)) + 1
              else:
                return 0
          else:
            todo($r.kind)
      of GENE_TAG:
        return self.gene.children.len
      of STRING_TAG:
        return self.str().to_runes().len
      of SYMBOL_TAG:
        return self.str().to_runes().len
      else:
        return 0
  else:
    # Not in NaN space - must be a float
    return 0
