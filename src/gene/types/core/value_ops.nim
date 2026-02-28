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

proc map_ptr*(v: Value): ptr MapObj {.inline.} =
  let u = cast[uint64](v)
  if (u and 0xFFFF_0000_0000_0000u64) != MAP_TAG:
    raise newException(ValueError, "Value is not a map")
  cast[ptr MapObj](u and PAYLOAD_MASK)

template map_data*(v: Value): var Table[Key, Value] =
  map_ptr(v).map

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
      return a.set == b.set
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

#################### Value ######################

# Forward declaration
converter to_int*(v: Value): int64 {.inline, noSideEffect.}

proc `==`*(a, b: Value): bool {.no_side_effect.} =
  if cast[uint64](a) == cast[uint64](b):
    return true

  {.cast(gcsafe).}:
    let u1 = cast[uint64](a)
    let u2 = cast[uint64](b)

    # Check if both are strings and compare them
    let tag1 = u1 and 0xFFFF_0000_0000_0000u64
    let tag2 = u2 and 0xFFFF_0000_0000_0000u64

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
        result = "["
        for i, v in array_data(self):
          if i > 0:
            result &= " "
          result &= v.str_no_quotes()
        result &= "]"
      of VkSet:
        result = "#{"
        var first = true
        for v in self.ref.set:
          if not first:
            result &= " "
          result &= v.str_no_quotes()
          first = false
        result &= "}"
      of VkMap:
        result = "{"
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
        result = $self.ref.date_year & "-" & $self.ref.date_month & "-" & $self.ref.date_day
      of VkDateTime:
        result = $self.ref.dt_year & "-" & $self.ref.dt_month & "-" & $self.ref.dt_day &
                 " " & $self.ref.dt_hour & ":" & $self.ref.dt_minute & ":" & $self.ref.dt_second
      of VkTime:
        result = $self.ref.time_hour & ":" & $self.ref.time_minute & ":" & $self.ref.time_second
      of VkFuture:
        result = "<Future " & $self.ref.future.state & ">"
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
        result = "["
        for i, v in array_data(self):
          if i > 0:
            result &= " "
          result &= $v
        result &= "]"
      of VkSet:
        result = "#{"
        var first = true
        for v in self.ref.set:
          if not first:
            result &= " "
          result &= $v
          first = false
        result &= "}"
      of VkMap:
        result = "{"
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
        result = $self.ref.date_year & "-" & $self.ref.date_month & "-" & $self.ref.date_day
      of VkDateTime:
        result = $self.ref.dt_year & "-" & $self.ref.dt_month & "-" & $self.ref.dt_day &
                 " " & $self.ref.dt_hour & ":" & $self.ref.dt_minute & ":" & $self.ref.dt_second
      of VkTime:
        result = $self.ref.time_hour & ":" & $self.ref.time_minute & ":" & $self.ref.time_second
      of VkFuture:
        result = "<Future " & $self.ref.future.state & ">"
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
              return r.bytes_data[i].to_value()
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
          of VkSet:
            return r.set.len
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
