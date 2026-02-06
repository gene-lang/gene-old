import math, hashes, tables, sets, re, bitops, unicode, strutils, strformat
import locks
import random
import times
import os
import asyncdispatch  # For async I/O support

import ./type_defs
export type_defs

#################### NaN Boxing implementation ####################
# We use the negative quiet NaN space (0xFFF0-0xFFFF prefix) for non-float values
# This allows all valid IEEE 754 floats to work correctly

const NAN_MASK* = 0xFFF0_0000_0000_0000u64

# Size limits for immediate integers (48-bit)
const SMALL_INT_MIN* = -(1'i64 shl 47)
const SMALL_INT_MAX* = (1'i64 shl 47) - 1

# Legacy constants for compatibility
const I64_MASK* = 0xC000_0000_0000_0000u64  # Will be removed

# Special values (using SPECIAL_TAG)
const NIL* = Value(raw: SPECIAL_TAG or 0)
const TRUE* = Value(raw: SPECIAL_TAG or 1)
const FALSE* = Value(raw: SPECIAL_TAG or 2)

const VOID* = Value(raw: SPECIAL_TAG or 3)
const PLACEHOLDER* = Value(raw: SPECIAL_TAG or 4)
# Used when a key does not exist in a map
const NOT_FOUND* = Value(raw: SPECIAL_TAG or 5)

# Special variable used by the parser
const PARSER_IGNORE* = Value(raw: SPECIAL_TAG or 6)

# Character encoding in special values (using SPECIAL_TAG prefix)
const CHAR_MASK = 0xFFF1_0000_0001_0000u64
const CHAR2_MASK = 0xFFF1_0000_0002_0000u64
const CHAR3_MASK = 0xFFF1_0000_0003_0000u64
const CHAR4_MASK = 0xFFF1_0000_0004_0000u64

# String constants

const EMPTY_STRING* = Value(raw: STRING_TAG)  # Empty string is a null pointer with STRING_TAG

const BIGGEST_INT = 2^61 - 1

#################### Forward declarations #################
# Value basics
proc kind*(v: Value): ValueKind {.inline.}
proc `==`*(a, b: Value): bool {.no_side_effect.}
converter to_bool*(v: Value): bool {.inline.}
proc `$`*(self: Value): string {.gcsafe.}
proc `$`*(self: ptr Reference): string
proc `$`*(self: ptr Gene): string
template gene*(v: Value): ptr Gene =
  if (cast[uint64](v) and 0xFFFF_0000_0000_0000u64) == GENE_TAG:
    cast[ptr Gene](cast[uint64](v) and PAYLOAD_MASK)
  else:
    raise newException(ValueError, "Value is not a gene")

# String/symbol helpers
proc new_str*(s: string): ptr String
proc new_str_value*(s: string): Value
proc str*(v: Value): string {.inline.}
converter to_value*(v: char): Value {.inline.}
converter to_value*(v: Rune): Value {.inline.}

# Scope/namespace helpers
proc update*(self: var Scope, scope: Scope) {.inline.}
proc `[]=`*(self: Namespace, key: Key, val: Value) {.inline.}

#################### Runtime globals #################

var VM* {.threadvar.}: ptr VirtualMachine   # The current virtual machine (per-thread)

# Application is shared across all threads (initialized once by main thread)
# After initialization, it's read-only so no locking needed
var App*: Value

# Threading support
const CHANNEL_LIMIT* = 1000  # Maximum messages in channel
const MAX_THREADS* = 64      # Maximum number of threads in pool

# Thread pool is shared across all threads (protected by thread_pool_lock in vm/thread.nim)
var THREADS*: array[MAX_THREADS, ThreadMetadata]

var VmCreatedCallbacks*: seq[VmCallback] = @[]

# Callbacks invoked on each event loop iteration (used by HTTP handler queue, etc.)
type EventLoopCallback* = proc(vm: ptr VirtualMachine) {.gcsafe.}
var EventLoopCallbacks*: seq[EventLoopCallback] = @[]

# Flag to track if gene namespace has been initialized (thread-local for worker threads)
var gene_namespace_initialized* {.threadvar.}: bool

# Current thread ID (thread-local, 0 for main thread)
var current_thread_id* {.threadvar.}: int

randomize()

# Value conversion helpers
proc toValue*(raw: uint64): Value {.inline.} =
  ## Convert raw uint64 to Value (for interfacing with cast-heavy code)
  Value(raw: raw)

proc toRaw*(v: Value): uint64 {.inline.} =
  ## Extract raw uint64 from Value
  v.raw

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
  # Can't assign to discriminant directly, use direct memory write
  # ref_count is 8 bytes, kind starts at offset 8
  var k = kind
  copy_mem(cast[pointer](cast[uint](result) + 8), addr k, 2)

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

#################### Symbol #####################

var SYMBOLS*: ManagedSymbols
var SYMBOLS_LOCK: Lock

initLock(SYMBOLS_LOCK)

proc get_symbol*(i: int): string {.inline.} =
  {.cast(gcsafe).}:
    acquire(SYMBOLS_LOCK)
    try:
      result = SYMBOLS.store[i]
    finally:
      release(SYMBOLS_LOCK)

proc get_symbol_gcsafe*(i: int): string {.inline, gcsafe.} =
  {.cast(gcsafe).}:
    acquire(SYMBOLS_LOCK)
    try:
      result = SYMBOLS.store[i]
    finally:
      release(SYMBOLS_LOCK)

proc to_symbol_value*(s: string): Value =
  {.cast(gcsafe).}:
    acquire(SYMBOLS_LOCK)
    try:
      let found = SYMBOLS.map.get_or_default(s, -1)
      if found != -1:
        let i = found.uint64
        result = cast[Value](SYMBOL_TAG or i)
      else:
        let new_id = SYMBOLS.store.len.uint64
        # Ensure symbol ID fits in 48 bits
        assert new_id <= PAYLOAD_MASK, "Too many symbols for NaN boxing"
        result = cast[Value](SYMBOL_TAG or new_id)
        SYMBOLS.map[s] = SYMBOLS.store.len
        SYMBOLS.store.add(s)
    finally:
      release(SYMBOLS_LOCK)

proc to_key*(s: string): Key {.inline.} =
  cast[Key](to_symbol_value(s))

# Extract symbol index from Key for symbol table lookup
# Key is a symbol value cast to int64, so we need to extract the symbol index
proc symbol_index*(k: Key): int {.inline.} =
  int(cast[uint64](k) and PAYLOAD_MASK)


#################### Value ######################

proc `==`*(a, b: Value): bool {.no_side_effect.} =
  if cast[uint64](a) == cast[uint64](b):
    return true

  {.cast(gcsafe).}:
    let u1 = cast[uint64](a)
    let u2 = cast[uint64](b)

    # Check if both are strings and compare them
    let tag1 = u1 and 0xFFFF_0000_0000_0000u64
    let tag2 = u2 and 0xFFFF_0000_0000_0000u64

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

# Forward declaration
converter to_int*(v: Value): int64 {.inline, noSideEffect.}

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
          of VkSelector, VkRegex:
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
  elif is_small_int(v):
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

#################### Int ########################

# NaN boxing for integers - supports 48-bit immediate values

converter to_value*(v: int): Value {.inline, noSideEffect.} =
  let i = v.int64
  if i >= SMALL_INT_MIN and i <= SMALL_INT_MAX:
    # Fits in 48 bits - use NaN boxing
    result = Value(raw: SMALL_INT_TAG or (cast[uint64](i) and PAYLOAD_MASK))
  else:
    # TODO: Allocate BigInt for values outside 48-bit range
    raise newException(OverflowDefect, "Integer " & $i & " outside supported range")

converter to_value*(v: int16): Value {.inline, noSideEffect.} =
  # int16 always fits in 48 bits
  result = Value(raw: SMALL_INT_TAG or (cast[uint64](v.int64) and PAYLOAD_MASK))

converter to_value*(v: int32): Value {.inline, noSideEffect.} =
  # int32 always fits in 48 bits
  result = Value(raw: SMALL_INT_TAG or (cast[uint64](v.int64) and PAYLOAD_MASK))

converter to_value*(v: int64): Value {.inline, noSideEffect.} =
  if v >= SMALL_INT_MIN and v <= SMALL_INT_MAX:
    # Fits in 48 bits - use NaN boxing
    result = Value(raw: SMALL_INT_TAG or (cast[uint64](v) and PAYLOAD_MASK))
  else:
    # TODO: Allocate BigInt for values outside 48-bit range
    raise newException(OverflowDefect, "Integer " & $v & " outside supported range")

converter to_int*(v: Value): int64 {.inline, noSideEffect.} =
  if is_small_int(v):
    # Extract and sign-extend from 48 bits
    let raw = v.raw and PAYLOAD_MASK
    if (raw and 0x8000_0000_0000u64) != 0:
      # Negative - sign extend
      result = cast[int64](raw or 0xFFFF_0000_0000_0000u64)
    else:
      result = cast[int64](raw)
  else:
    # TODO: Handle BigInt conversion
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

#################### Application #################

# Forward decls for namespace helpers used here
proc new_namespace*(): Namespace {.gcsafe.}
proc new_namespace*(name: string): Namespace {.gcsafe.}
proc new_namespace*(parent: Namespace): Namespace {.gcsafe.}

proc app*(self: Value): Application {.inline.} =
  self.ref.app

proc new_app*(): Application =
  result = Application()
  let global = new_namespace("global")
  result.ns = global

#################### Namespace ###################

proc ns*(self: Value): Namespace {.inline.} =
  self.ref.ns

proc to_value*(self: Namespace): Value {.inline.} =
  let r = new_ref(VkNamespace)
  r.ns = self
  result = r.to_ref_value()

proc new_namespace*(): Namespace =
  return Namespace(
    name: "<root>",
    members: Table[Key, Value](),
  )

proc new_namespace*(parent: Namespace): Namespace =
  return Namespace(
    parent: parent,
    name: "<root>",
    members: Table[Key, Value](),
  )

proc new_namespace*(name: string): Namespace =
  return Namespace(
    name: name,
    members: Table[Key, Value](),
  )

proc new_namespace*(parent: Namespace, name: string): Namespace =
  return Namespace(
    parent: parent,
    name: name,
    members: Table[Key, Value](),
  )

proc root*(self: Namespace): Namespace =
  if self.name == "<root>":
    return self
  else:
    return self.parent.root

proc get_module*(self: Namespace): Module =
  if self.module == nil:
    if self.parent != nil:
      return self.parent.get_module()
    else:
      return
  else:
    return self.module

proc package*(self: Namespace): Package =
  self.get_module().pkg

proc has_key*(self: Namespace, key: Key): bool {.inline.} =
  return self.members.has_key(key) or (self.parent != nil and self.parent.has_key(key))

proc `[]`*(self: Namespace, key: Key): Value =
  let found = self.members.get_or_default(key, NOT_FOUND)
  if found != NOT_FOUND:
    return found
  elif not self.stop_inheritance and self.parent != nil:
    return self.parent[key]
  else:
    return NIL
    # return NOT_FOUND
    # raise new_exception(NotDefinedException, get_symbol(key.int64) & " is not defined")

proc locate*(self: Namespace, key: Key): (Value, Namespace) =
  let found = self.members.get_or_default(key, NOT_FOUND)
  if found != NOT_FOUND:
    result = (found, self)
  elif not self.stop_inheritance and self.parent != nil:
    result = self.parent.locate(key)
  else:
    not_allowed()

proc `[]=`*(self: Namespace, key: Key, val: Value) {.inline.} =
  self.members[key] = val
  self.version.inc()  # Invalidate caches on mutation

proc get_members*(self: Namespace): Value =
  todo()
  # result = new_gene_map()
  # for k, v in self.members:
  #   result.map[k] = v

proc member_names*(self: Namespace): Value =
  todo()
  # result = new_gene_vec()
  # for k, _ in self.members:
  #   result.vec.add(k)

# proc on_member_missing*(frame: Frame, self: Value, args: Value): Value =
proc on_member_missing*(vm_data: ptr VirtualMachine, args: Value): Value =
  todo()
  # let self = args.gene_type
  # case self.kind
  # of VkNamespace:
  #   self.ns.on_member_missing.add(args.gene_children[0])
  # of VkClass:
  #   self.class.ns.on_member_missing.add(args.gene_children[0])
  # else:
  #   todo("member_missing " & $self.kind)

#################### Scope #######################

# Scope pooling for performance (like Frame pooling)
var SCOPES* {.threadvar.}: seq[Scope]
var SCOPE_ALLOCS* {.threadvar.}: int
var SCOPE_REUSES* {.threadvar.}: int

proc reset_scope*(self: Scope) {.inline.} =
  ## Reset a scope for reuse from pool
  self.tracker = nil
  self.parent = nil
  self.members.setLen(0)  # Clear members but keep capacity

proc free*(self: Scope) =
  {.push checks: off, optimization: speed.}
  self.ref_count.dec()
  if self.ref_count == 0:
    # Free parent first
    if self.parent != nil:
      self.parent.free()
    # Return to pool instead of deallocating
    self.reset_scope()
    SCOPES.add(self)
  {.pop.}

proc new_scope*(tracker: ScopeTracker): Scope {.inline.} =
  {.push checks: off, optimization: speed.}
  if SCOPES.len > 0:
    result = SCOPES.pop()
    SCOPE_REUSES.inc()
  else:
    result = cast[Scope](alloc0(sizeof(ScopeObj)))
    result.members = newSeq[Value]()  # Only allocate members seq on first creation
    SCOPE_ALLOCS.inc()
  result.ref_count = 1
  result.tracker = tracker
  result.parent = nil
  {.pop.}

proc update*(self: var Scope, scope: Scope) {.inline.} =
  {.push checks: off, optimization: speed.}
  if scope != nil:
    scope.ref_count.inc()
  if self != nil:
    self.free()
  self = scope
  {.pop.}

proc max*(self: Scope): int16 {.inline.} =
  return self.members.len.int16

proc set_parent*(self: Scope, parent: Scope) {.inline.} =
  parent.ref_count.inc()
  self.parent = parent

proc new_scope*(tracker: ScopeTracker, parent: Scope): Scope =
  result = new_scope(tracker)
  if not parent.is_nil():
    result.set_parent(parent)

proc locate(self: ScopeTracker, key: Key, max: int): VarIndex =
  let found = self.mappings.get_or_default(key, -1)
  if found >= 0 and found < max:
    return VarIndex(parent_index: 0, local_index: found)
  elif self.parent.is_nil():
    return VarIndex(parent_index: 0, local_index: -1)
  else:
    result = self.parent.locate(key, self.parent_index_max.int)
    if self.next_index > 0: # if current scope is not empty
      result.parent_index.inc()

proc locate*(self: ScopeTracker, key: Key): VarIndex =
  let found = self.mappings.get_or_default(key, -1)
  if found >= 0:
    return VarIndex(parent_index: 0, local_index: found)
  elif self.parent.is_nil():
    return VarIndex(parent_index: 0, local_index: -1)
  else:
    result = self.parent.locate(key, self.parent_index_max.int)
    # Only increment parent_index if we actually created a runtime scope
    # (indicated by scope_started flag or having variables)
    if self.next_index > 0 or self.scope_started:
      result.parent_index.inc()

#################### ScopeTracker ################

proc new_scope_tracker*(): ScopeTracker =
  ScopeTracker()

proc new_scope_tracker*(parent: ScopeTracker): ScopeTracker =
  result = ScopeTracker()
  var p = parent
  while p != nil:
    if p.next_index > 0:
      result.parent = p
      result.parent_index_max = p.next_index
      return
    p = p.parent

proc copy_scope_tracker*(source: ScopeTracker): ScopeTracker =
  result = ScopeTracker()
  result.next_index = source.next_index
  result.parent_index_max = source.parent_index_max
  result.parent = source.parent
  result.type_expectations = source.type_expectations
  result.type_expectation_ids = source.type_expectation_ids
  # Copy the mappings table
  for key, value in source.mappings:
    result.mappings[key] = value

proc add*(self: var ScopeTracker, name: Key) =
  self.mappings[name] = self.next_index
  self.next_index.inc()

proc snapshot_scope_tracker*(tracker: ScopeTracker): ScopeTrackerSnapshot =
  if tracker == nil:
    return nil

  result = ScopeTrackerSnapshot(
    next_index: tracker.next_index,
    parent_index_max: tracker.parent_index_max,
    scope_started: tracker.scope_started,
    mappings: @[],
    type_expectations: tracker.type_expectations,
    type_expectation_ids: tracker.type_expectation_ids,
    parent: snapshot_scope_tracker(tracker.parent)
  )

  for key, value in tracker.mappings:
    result.mappings.add((key, value))

proc materialize_scope_tracker*(snapshot: ScopeTrackerSnapshot): ScopeTracker =
  if snapshot == nil:
    return nil

  result = ScopeTracker(
    next_index: snapshot.next_index,
    parent_index_max: snapshot.parent_index_max,
    scope_started: snapshot.scope_started,
    type_expectations: snapshot.type_expectations,
    type_expectation_ids: snapshot.type_expectation_ids,
    parent: materialize_scope_tracker(snapshot.parent)
  )

  for pair in snapshot.mappings:
    result.mappings[pair[0]] = pair[1]

proc new_function_def_info*(tracker: ScopeTracker, body: CompilationUnit = nil, input: Value = NIL): FunctionDefInfo =
  var body_value = NIL
  if body != nil:
    let cu_ref = new_ref(VkCompiledUnit)
    cu_ref.cu = body
    body_value = cu_ref.to_ref_value()

  result = FunctionDefInfo(
    input: input,
    scope_tracker: tracker,
    compiled_body: body_value
  )

proc to_value*(info: FunctionDefInfo): Value =
  let r = new_ref(VkFunctionDef)
  r.function_def = info
  result = r.to_ref_value()

proc to_function_def_info*(value: Value): FunctionDefInfo =
  if value.kind != VkFunctionDef:
    not_allowed("Expected FunctionDef info value")
  result = value.ref.function_def

#################### Pattern Matching ############

proc new_match_matcher*(): RootMatcher =
  result = RootMatcher(
    mode: MatchExpression,
    return_type_id: NO_TYPE_ID,
  )

proc new_arg_matcher*(): RootMatcher =
  result = RootMatcher(
    mode: MatchArguments,
    return_type_id: NO_TYPE_ID,
  )

proc new_matcher*(root: RootMatcher, kind: MatcherKind): Matcher =
  result = Matcher(
    root: root,
    kind: kind,
    default_value: PLACEHOLDER, # PLACEHOLDER marks "no default" (distinct from explicit nil)
    type_id: NO_TYPE_ID,
  )

proc is_empty*(self: RootMatcher): bool =
  self.children.len == 0

proc has_default*(self: Matcher): bool {.inline.} =
  self.default_value.kind != VkPlaceholder

proc required*(self: Matcher): bool =
  # A parameter is required if it has no default and is not a splat parameter.
  # Properties without defaults are required too.
  return (not self.is_splat) and (not self.has_default())

proc check_hint*(self: RootMatcher) =
  if self.children.len == 0:
    self.hint_mode = MhNone
  else:
    self.hint_mode = MhSimpleData
    for item in self.children:
      if item.kind != MatchData or not item.required:
        self.hint_mode = MhDefault
        return

# proc hint*(self: RootMatcher): MatchingHint =
#   if self.children.len == 0:
#     result.mode = MhNone
#   else:
#     result.mode = MhSimpleData
#     for item in self.children:
#       if item.kind != MatchData or not item.required:
#         result.mode = MhDefault
#         return

# proc new_matched_field*(name: string, value: Value): MatchedField =
#   result = MatchedField(
#     name: name,
#     value: value,
#   )

proc props*(self: seq[Matcher]): HashSet[Key] =
  for m in self:
    if m.kind == MatchProp and not m.is_splat:
      result.incl(m.name_key)

proc prop_splat*(self: seq[Matcher]): Key =
  for m in self:
    if m.kind == MatchProp and m.is_splat:
      return m.name_key

proc parse*(self: RootMatcher, v: Value)

proc calc_next*(self: Matcher) =
  var last: Matcher = nil
  for m in self.children.mitems:
    m.calc_next()
    if m.kind in @[MatchData, MatchLiteral]:
      if last != nil:
        last.next = m
      last = m

proc calc_next*(self: RootMatcher) =
  var last: Matcher = nil
  for m in self.children.mitems:
    m.calc_next()
    if m.kind in @[MatchData, MatchLiteral]:
      if last != nil:
        last.next = m
      last = m

proc calc_min_left*(self: Matcher) =
  {.push checks: off}
  var min_left = 0
  var i = self.children.len
  while i > 0:
    i -= 1
    let m = self.children[i]
    m.calc_min_left()
    m.min_left = min_left
    if m.required:
      min_left += 1
  {.pop.}

proc calc_min_left*(self: RootMatcher) =
  {.push checks: off}
  var min_left = 0
  var i = self.children.len
  while i > 0:
    i -= 1
    let m = self.children[i]
    m.calc_min_left()
    m.min_left = min_left
    if m.required:
      min_left += 1
  {.pop.}

proc parse(self: RootMatcher, group: var seq[Matcher], v: Value) =
  {.push checks: off}
  case v.kind:
    of VkSymbol:
      if v.str[0] == '^':
        let m = new_matcher(self, MatchProp)
        if v.str.ends_with("..."):
          m.is_splat = true
          if v.str[1] == '^':
            m.name_key = v.str[2..^4].to_key()
            m.is_prop = true
            m.default_value = TRUE  # ^^param => default true
          elif v.str[1] == '!':
            m.name_key = v.str[2..^4].to_key()
            m.is_prop = true
            m.default_value = NIL  # ^!param => default false
          else:
            m.name_key = v.str[1..^4].to_key()
            m.is_prop = true  # Named parameters always have is_prop = true
        else:
          if v.str[1] == '^':
            m.name_key = v.str[2..^1].to_key()
            m.is_prop = true
            m.default_value = TRUE   # ^^param => default true
          elif v.str[1] == '!':
            m.name_key = v.str[2..^1].to_key()
            m.is_prop = true
            m.default_value = NIL  # ^!param => default false
          else:
            m.name_key = v.str[1..^1].to_key()
            m.is_prop = true  # Named parameters always have is_prop = true
        group.add(m)
      else:
        let m = new_matcher(self, MatchData)
        group.add(m)
        if v.str != "_":
          if v.str.ends_with("..."):
            m.is_splat = true
            if v.str[0] == '^':
              m.name_key = v.str[1..^4].to_key()
              m.is_prop = true
            else:
              m.name_key = v.str[0..^4].to_key()
          else:
            if v.str[0] == '^':
              m.name_key = v.str[1..^1].to_key()
              m.is_prop = true
            else:
              m.name_key = v.str.to_key()
    of VkComplexSymbol:
      if v.ref.csymbol[0] == "^":
        todo("parse " & $v)
      else:
        var m = new_matcher(self, MatchData)
        group.add(m)
        m.is_prop = true
        let name = v.ref.csymbol[1]
        if name.ends_with("..."):
          m.is_splat = true
          m.name_key = name[0..^4].to_key()
        else:
          m.name_key = name.to_key()
    of VkArray:
      var i = 0
      let arr = array_data(v)
      while i < arr.len:
        let item = arr[i]
        i += 1
        if item.kind == VkArray:
          let m = new_matcher(self, MatchData)
          group.add(m)
          self.parse(m.children, item)
        else:
          self.parse(group, item)
          if i < arr.len and arr[i] == "=".to_symbol_value():
            i += 1
            let last_matcher = group[^1]
            let value = arr[i]
            i += 1
            last_matcher.default_value = value
    of VkQuote:
      todo($VkQuote)
      # var m = new_matcher(self, MatchLiteral)
      # m.literal = v.quote
      # m.name = "<literal>"
      # group.add(m)
    else:
      todo("parse " & $v.kind)
  {.pop.}

proc parse*(self: RootMatcher, v: Value) =
  if v == nil or v == to_symbol_value("_"):
    return
  self.parse(self.children, v)
  self.calc_min_left()
  self.calc_next()

proc new_arg_matcher*(value: Value): RootMatcher =
  result = new_arg_matcher()
  result.parse(value)
  result.check_hint()

proc is_union_gene(gene: ptr Gene): bool =
  if gene == nil:
    return false
  if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
    return true
  for child in gene.children:
    if child.kind == VkSymbol and child.str == "|":
      return true
  return false

proc union_members(v: Value): seq[Value] =
  if v.kind == VkGene and v.gene != nil and is_union_gene(v.gene):
    let gene = v.gene
    if gene.`type`.kind == VkSymbol and gene.`type`.str == "|":
      return gene.children
    result.add(gene.`type`)
    var i = 0
    while i < gene.children.len:
      let child = gene.children[i]
      if child.kind == VkSymbol and child.str == "|":
        if i + 1 < gene.children.len:
          result.add(gene.children[i + 1])
        i += 2
      else:
        i += 1
    return result
  result = @[v]

proc type_expr_to_string*(v: Value): string =
  case v.kind
  of VkSymbol:
    return v.str
  of VkString:
    return v.str
  of VkGene:
    let gene = v.gene
    if gene == nil:
      return "Any"
    if gene.`type`.kind == VkSymbol and gene.`type`.str == "Fn":
      var params: seq[string] = @[]
      if gene.children.len > 0 and gene.children[0].kind == VkArray:
        let items = array_data(gene.children[0])
        var i = 0
        while i < items.len:
          let item = items[i]
          if item.kind == VkSymbol and item.str.startsWith("^"):
            let label = item.str[1..^1]
            if i + 1 < items.len:
              params.add("^" & label & " " & type_expr_to_string(items[i + 1]))
              i += 2
            else:
              params.add("^" & label & " Any")
              i += 1
          else:
            params.add(type_expr_to_string(item))
            i += 1
      let ret =
        if gene.children.len > 1: type_expr_to_string(gene.children[1]) else: "Any"
      var effects: seq[string] = @[]
      if gene.children.len > 2:
        let maybe_bang = gene.children[2]
        if maybe_bang.kind == VkSymbol and maybe_bang.str == "!" and gene.children.len > 3:
          let effect_list = gene.children[3]
          if effect_list.kind == VkArray:
            for eff in array_data(effect_list):
              effects.add(type_expr_to_string(eff))
      let effect_suffix =
        if effects.len > 0: " ! [" & effects.join(" ") & "]" else: ""
      return "(Fn [" & params.join(" ") & "] " & ret & effect_suffix & ")"
    if is_union_gene(gene):
      var parts: seq[string] = @[]
      for member in union_members(v):
        parts.add(type_expr_to_string(member))
      return "(" & parts.join(" | ") & ")"
    if gene.`type`.kind == VkSymbol:
      var parts: seq[string] = @[gene.`type`.str]
      for child in gene.children:
        parts.add(type_expr_to_string(child))
      return "(" & parts.join(" ") & ")"
    return "Any"
  else:
    return "Any"

#################### Function ####################

proc new_fn*(name: string, matcher: RootMatcher, body: sink seq[Value]): Function =
  return Function(
    name: name,
    matcher: matcher,
    # matching_hint: matcher.hint,
    body: body,
  )

proc to_function*(node: Value): Function {.gcsafe.} =
  if node.kind != VkGene:
    raise new_exception(type_defs.Exception, "Expected Gene for function definition, got " & $node.kind)

  if node.gene == nil:
    raise new_exception(type_defs.Exception, "Gene pointer is nil")

  var return_type_override = ""

  # Extract type annotations as name -> type_name mapping, and strip them from args
  proc strip_type_annotations(args: Value, type_map: var Table[string, string]): Value =
    if args.kind != VkArray:
      return args
    let src = array_data(args)
    var out_args = new_array_value()
    var i = 0
    while i < src.len:
      let item = src[i]
      if item.kind == VkSymbol and item.str.endsWith(":"):
        let base = item.str[0..^2]
        array_data(out_args).add(base.to_symbol_value())
        i.inc
        if i < src.len:
          let type_val = src[i]
          if not type_map.hasKey(base):
            type_map[base] = type_expr_to_string(type_val)
          i.inc # Skip type expression
        continue
      elif item.kind == VkArray:
        array_data(out_args).add(strip_type_annotations(item, type_map))
      else:
        array_data(out_args).add(item)
      i.inc
    return out_args

  # Apply collected type annotations to matcher children
  proc apply_type_annotations(matcher: RootMatcher, type_map: Table[string, string]) =
    if type_map.len == 0:
      return
    for child in matcher.children:
      try:
        let name = cast[Value](child.name_key).str
        if type_map.hasKey(name):
          child.type_name = type_map[name]
          matcher.has_type_annotations = true
      except CatchableError:
        discard
    # When type annotations are present, disable the simple-data fast path
    # so that process_args_core is always called (which does type validation)
    if matcher.has_type_annotations:
      matcher.hint_mode = MhDefault

  proc load_type_annotations_from_props(node: ptr Gene, type_map: var Table[string, string], return_type: var string) =
    if node == nil:
      return
    let param_key = TC_PARAM_TYPES_KEY.to_key()
    if node.props.has_key(param_key):
      let map_val = node.props[param_key]
      if map_val.kind == VkMap:
        for k, v in map_data(map_val):
          try:
            let name = cast[Value](k).str
            if v.kind in {VkString, VkSymbol}:
              type_map[name] = v.str
            else:
              type_map[name] = type_expr_to_string(v)
          except CatchableError:
            discard
    let return_key = TC_RETURN_TYPE_KEY.to_key()
    if node.props.has_key(return_key):
      let val = node.props[return_key]
      if val.kind in {VkString, VkSymbol}:
        return_type = val.str
      else:
        return_type = type_expr_to_string(val)

  var name: string
  let matcher = new_arg_matcher()
  var body_start: int
  var is_generator = false
  var is_macro_like = false
  var type_map = initTable[string, string]()
  load_type_annotations_from_props(node.gene, type_map, return_type_override)

  if node.gene.children.len == 0:
    raise new_exception(type_defs.Exception, "Invalid function definition: expected name or argument list")
  let first = node.gene.children[0]
  case first.kind:
    of VkArray:
      name = "<unnamed>"
      matcher.parse(strip_type_annotations(first, type_map))
      apply_type_annotations(matcher, type_map)
      body_start = 1
    of VkSymbol, VkString:
      name = first.str
      # Check if function name ends with ! (macro-like function)
      if name.len > 0 and name[^1] == '!':
        is_macro_like = true
      # Check if function name ends with * (generator function)
      elif name.len > 0 and name[^1] == '*':
        is_generator = true
      if node.gene.children.len < 2:
        raise new_exception(type_defs.Exception, "Invalid function definition: expected argument list array")
      let args = strip_type_annotations(node.gene.children[1], type_map)
      if args.kind != VkArray:
        raise new_exception(type_defs.Exception, "Invalid function definition: arguments must be an array")
      matcher.parse(args)
      apply_type_annotations(matcher, type_map)
      body_start = 2
    of VkComplexSymbol:
      name = first.ref.csymbol[^1]
      # Check if function name ends with ! (macro-like function)
      if name.len > 0 and name[^1] == '!':
        is_macro_like = true
      # Check if function name ends with * (generator function)
      elif name.len > 0 and name[^1] == '*':
        is_generator = true
      if node.gene.children.len < 2:
        raise new_exception(type_defs.Exception, "Invalid function definition: expected argument list array")
      let args = strip_type_annotations(node.gene.children[1], type_map)
      if args.kind != VkArray:
        raise new_exception(type_defs.Exception, "Invalid function definition: arguments must be an array")
      matcher.parse(args)
      apply_type_annotations(matcher, type_map)
      body_start = 2
    else:
      raise new_exception(type_defs.Exception, "Invalid function definition: expected name or argument list")

  matcher.check_hint()
  # Parse optional return type annotation: (-> Type)
  if body_start < node.gene.children.len:
    let maybe_arrow = node.gene.children[body_start]
    if maybe_arrow.kind == VkSymbol and maybe_arrow.str == "->":
      if body_start + 1 >= node.gene.children.len:
        raise new_exception(type_defs.Exception, "Invalid function definition: missing return type after ->")
      let ret_type = node.gene.children[body_start + 1]
      matcher.return_type_name = type_expr_to_string(ret_type)
      body_start += 2
  if return_type_override.len > 0:
    matcher.return_type_name = return_type_override

  var body: seq[Value] = @[]
  for i in body_start..<node.gene.children.len:
    body.add node.gene.children[i]

  # Check if function has async attribute from properties
  var is_async = false
  let async_key = "async".to_key()
  if node.gene.props.has_key(async_key) and node.gene.props[async_key] == TRUE:
    is_async = true
    discard  # Function is async

  # Check if function has generator flag from properties (^^generator syntax)
  let generator_key = "generator".to_key()
  if node.gene.props.has_key(generator_key) and node.gene.props[generator_key] == TRUE:
    is_generator = true

  # body = wrap_with_try(body)
  result = new_fn(name, matcher, body)
  result.async = is_async
  result.is_generator = is_generator
  result.is_macro_like = is_macro_like

# compile method is defined in compiler.nim

#################### Block #######################

proc new_block*(matcher: RootMatcher,  body: sink seq[Value]): Block =
  return Block(
    matcher: matcher,
    # matching_hint: matcher.hint,
    body: body,
  )

proc to_block*(node: Value): Block {.gcsafe.} =
  let matcher = new_arg_matcher()
  var body_start: int
  let type_val = node.gene.type

  if type_val.kind == VkSymbol and type_val.str == "block":
    # New syntax: (block [args] body...)
    if node.gene.children.len > 0 and node.gene.children[0].kind == VkArray:
      matcher.parse(node.gene.children[0])
      body_start = 1
    else:
      # (block body...) with no args array - treat as empty args
      body_start = 0
  elif type_val == "->".to_symbol_value():
    # Old syntax: (-> body...) - no parameters
    body_start = 0
  else:
    # Old syntax: (params -> body...) - params is the type
    matcher.parse(type_val)
    body_start = 1

  matcher.check_hint()
  var body: seq[Value] = @[]
  for i in body_start..<node.gene.children.len:
    body.add node.gene.children[i]

  # body = wrap_with_try(body)
  result = new_block(matcher, body)

# compile method needs to be defined - see compiler.nim

#################### Future ######################

proc new_future*(): FutureObj =
  result = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nil  # Synchronous future by default
  )

proc new_future*(nim_fut: Future[Value]): FutureObj =
  ## Create a FutureObj that wraps a Nim async future
  result = FutureObj(
    state: FsPending,
    value: NIL,
    success_callbacks: @[],
    failure_callbacks: @[],
    nim_future: nim_fut
  )

proc new_future_value*(): Value =
  let r = new_ref(VkFuture)
  r.future = new_future()
  return r.to_ref_value()

proc complete*(f: FutureObj, value: Value) =
  if f.state != FsPending:
    not_allowed("Future already completed")
  f.state = FsSuccess
  f.value = value
  # Execute success callbacks
  # Note: Callbacks are executed immediately when future completes
  # In real async, these would be scheduled on the event loop
  for callback in f.success_callbacks:
    if callback.kind == VkFunction:
      # Execute Gene function with value as argument
      # We need a VM instance to execute, but we don't have one here
      # This will be handled by update_from_nim_future which has VM access
      discard
    # For now, callbacks are stored but not executed here
    # They will be executed by update_from_nim_future or by explicit VM call

proc fail*(f: FutureObj, error: Value) =
  if f.state != FsPending:
    not_allowed("Future already completed")
  f.state = FsFailure
  f.value = error
  # Execute failure callbacks
  for callback in f.failure_callbacks:
    if callback.kind == VkFunction:
      # Execute Gene function with error as argument
      # We need a VM instance to execute, but we don't have one here
      # This will be handled by update_from_nim_future which has VM access
      discard
    # For now, callbacks are stored but not executed here
    # They will be executed by update_from_nim_future or by explicit VM call

proc update_from_nim_future*(f: FutureObj) =
  ## Check if the underlying Nim future has completed and update our state
  ## This should be called during event loop polling
  ## NOTE: This version doesn't execute callbacks - use update_future_from_nim in vm/async.nim for that
  if f.nim_future.isNil or f.state != FsPending:
    return  # No Nim future to check, or already completed

  if finished(f.nim_future):
    # Nim future has completed - copy its result
    if failed(f.nim_future):
      # Future failed with exception
      # TODO: Wrap exception properly when exception handling is ready
      f.state = FsFailure
      f.value = new_str_value("Async operation failed")
    else:
      # Future succeeded
      f.state = FsSuccess
      f.value = read(f.nim_future)

    # Execute appropriate callbacks
    if f.state == FsSuccess:
      for callback in f.success_callbacks:
        # TODO: Execute callback with value
        discard
    else:
      for callback in f.failure_callbacks:
        # TODO: Execute callback with error
        discard

#################### Enum ########################

proc new_enum*(name: string): EnumDef =
  return EnumDef(
    name: name,
    members: initTable[string, EnumMember]()
  )

proc new_enum_member*(parent: Value, name: string, value: int): EnumMember =
  return EnumMember(
    parent: parent,
    name: name,
    value: value
  )

proc to_value*(e: EnumDef): Value =
  let r = new_ref(VkEnum)
  r.enum_def = e
  return r.to_ref_value()

proc to_value*(m: EnumMember): Value =
  let r = new_ref(VkEnumMember)
  r.enum_member = m
  return r.to_ref_value()

proc add_member*(self: Value, name: string, value: int) =
  if self.kind != VkEnum:
    not_allowed("add_member can only be called on enums")
  let member = new_enum_member(self, name, value)
  self.ref.enum_def.members[name] = member

proc `[]`*(self: Value, name: string): Value =
  if self.kind != VkEnum:
    not_allowed("enum member access can only be used on enums")
  if name in self.ref.enum_def.members:
    return self.ref.enum_def.members[name].to_value()
  else:
    not_allowed("enum " & self.ref.enum_def.name & " has no member " & name)

#################### Native ######################

converter to_value*(f: NativeFn): Value {.inline.} =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  result = r.to_ref_value()

converter to_value*(t: type_defs.Thread): Value {.inline.} =
  let r = new_ref(VkThread)
  r.thread = t
  return r.to_ref_value()

converter to_value*(m: type_defs.ThreadMessage): Value {.inline.} =
  let r = new_ref(VkThreadMessage)
  r.thread_message = m
  return r.to_ref_value()

# Helper functions for new NativeFn signature
proc get_positional_arg*(args: ptr UncheckedArray[Value], index: int, has_keyword_args: bool): Value {.inline.} =
  ## Get positional argument (handles keyword offset automatically)
  let offset = if has_keyword_args: 1 else: 0
  return args[offset + index]

proc get_keyword_arg*(args: ptr UncheckedArray[Value], name: string): Value {.inline.} =
  ## Get keyword argument by name
  if args[0].kind == VkMap:
    return map_data(args[0]).get_or_default(name.to_key(), NIL)
  else:
    return NIL

proc has_keyword_arg*(args: ptr UncheckedArray[Value], name: string): bool {.inline.} =
  ## Check if keyword argument exists
  if args[0].kind == VkMap:
    return map_data(args[0]).hasKey(name.to_key())
  else:
    return false

proc get_positional_count*(arg_count: int, has_keyword_args: bool): int {.inline.} =
  ## Get the number of positional arguments
  if has_keyword_args: arg_count - 1 else: arg_count

# Helper functions specifically for native methods
proc get_self*(args: ptr UncheckedArray[Value], has_keyword_args: bool): Value {.inline.} =
  ## Get self object for native methods (always first positional argument)
  return get_positional_arg(args, 0, has_keyword_args)

proc get_method_arg*(args: ptr UncheckedArray[Value], index: int, has_keyword_args: bool): Value {.inline.} =
  ## Get method argument by index (index 0 = first argument after self)
  return get_positional_arg(args, index + 1, has_keyword_args)

proc get_method_arg_count*(arg_count: int, has_keyword_args: bool): int {.inline.} =
  ## Get the number of method arguments (excluding self)
  let positional_count = get_positional_count(arg_count, has_keyword_args)
  if positional_count > 0: positional_count - 1 else: 0

# Migration helpers
proc get_legacy_args*(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): seq[Value] =
  ## Helper to convert to seq[Value] for easier migration
  result = newSeq[Value]()
  let offset = if has_keyword_args: 1 else: 0
  for i in offset..<arg_count:
    result.add(args[i])

proc create_gene_args*(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
  ## For functions that need Gene object temporarily during migration
  var gene_args = new_gene_value()
  let offset = if has_keyword_args: 1 else: 0
  for i in offset..<arg_count:
    gene_args.gene.children.add(args[i])
  return gene_args

# Helper for calling native functions with proper casting
proc call_native_fn*(fn: NativeFn, vm: ptr VirtualMachine, args: openArray[Value], has_keyword_args: bool = false): Value {.inline.} =
  ## Helper to call native function with proper array casting
  if args.len == 0:
    return fn(vm, nil, 0, has_keyword_args)
  else:
    return fn(vm, cast[ptr UncheckedArray[Value]](args[0].unsafeAddr), args.len, has_keyword_args)

#################### Frame #######################
const INITIAL_FRAME_POOL_SIZE* = 128

var FRAMES* {.threadvar.}: seq[Frame]

proc init*(self: var CallBaseStack) {.inline.} =
  self.data = newSeq[uint16](0)

proc reset*(self: var CallBaseStack) {.inline.} =
  if self.data.len > 0:
    self.data.setLen(0)

proc push*(self: var CallBaseStack, base: uint16) {.inline.} =
  self.data.add(base)

proc pop*(self: var CallBaseStack): uint16 {.inline.} =
  assert self.data.len > 0, "Call base stack underflow"
  let idx = self.data.len - 1
  result = self.data[idx]
  self.data.setLen(idx)

proc peek*(self: CallBaseStack): uint16 {.inline.} =
  assert self.data.len > 0, "Call base stack is empty"
  result = self.data[self.data.len - 1]

proc is_empty*(self: CallBaseStack): bool {.inline.} =
  self.data.len == 0

proc reset_frame*(self: Frame) {.inline.} =
  # Reset only necessary fields, avoiding full memory clear
  self.kind = FkFunction
  self.caller_frame = nil
  self.caller_address = Address()
  self.caller_context = nil
  self.ns = nil
  self.scope = nil
  self.target = NIL
  self.args = NIL
  self.from_exec_function = false
  self.is_generator = false

  # GC: Clear the stack using raw memory operations to avoid triggering =copy hooks
  # The VM's pop operations already handle reference counting, so we just need to
  # zero the memory to prevent stale references without double-releasing.
  {.push boundChecks: off.}
  if self.stack_max > 0:
    zeroMem(addr self.stack[0], int(self.stack_max) * sizeof(Value))
  {.pop.}

  self.stack_index = 0
  self.stack_max = 0
  self.call_bases.reset()
  self.collection_bases.reset()

proc free*(self: var Frame) =
  {.push checks: off, optimization: speed.}
  self.ref_count.dec()
  if self.ref_count <= 0:
    if self.caller_frame != nil:
      self.caller_frame.free()
    # Only free scope if frame owns it (functions without parameters borrow parent scope)
    # For now, we rely on IkScopeEnd to manage scopes properly
    # TODO: Track whether frame owns or borrows its scope
    if self.scope != nil and false:  # Disabled for now - IkScopeEnd handles it
      self.scope.free()
    self.reset_frame()
    FRAMES.add(self)
  {.pop.}

var FRAME_ALLOCS* {.threadvar.}: int
var FRAME_REUSES* = 0

proc new_frame*(): Frame {.inline.} =
  {.push boundChecks: off, overflowChecks: off.}
  if FRAMES.len > 0:
    result = FRAMES.pop()
    FRAME_REUSES.inc()
  else:
    result = cast[Frame](alloc0(sizeof(FrameObj)))
    FRAME_ALLOCS.inc()
  result.ref_count = 1
  result.stack_index = 0
  result.stack_max = 0
  result.call_bases.init()
  result.collection_bases.init()
  {.pop.}

proc new_frame*(ns: Namespace): Frame {.inline.} =
  result = new_frame()
  result.ns = ns

proc new_frame*(caller_frame: Frame, caller_address: Address): Frame {.inline.} =
  result = new_frame()
  caller_frame.ref_count.inc()
  result.caller_frame = caller_frame
  result.caller_address = caller_address

proc new_frame*(caller_frame: Frame, caller_address: Address, scope: Scope): Frame {.inline.} =
  result = new_frame()
  caller_frame.ref_count.inc()
  result.caller_frame = caller_frame
  result.caller_address = caller_address
  result.scope = scope

proc update*(self: var Frame, f: Frame) {.inline.} =
  {.push checks: off, optimization: speed.}
  f.ref_count.inc()
  if self != nil:
    self.free()
  self = f
  {.pop.}

template current*(self: Frame): Value =
  self.stack[self.stack_index - 1]

proc replace*(self: var Frame, v: Value) {.inline.} =
  {.push boundChecks: off, overflowChecks: off.}
  self.stack[self.stack_index - 1] = v
  {.pop.}

template push*(self: var Frame, value: sink Value) =
  {.push boundChecks: off, overflowChecks: off.}
  if self.stack_index >= self.stack.len.uint16:
    var detail = ""
    if not VM.isNil and not VM.cu.is_nil:
      let pc = VM.pc
      detail = " at pc " & $pc
      if pc >= 0 and pc < VM.cu.instructions.len:
        detail &= " (" & $VM.cu.instructions[pc].kind & ")"
    raise new_exception(type_defs.Exception, "Stack overflow: frame stack exceeded " & $self.stack.len & detail)
  self.stack[self.stack_index] = value
  self.stack_index.inc()
  # Track maximum stack position for GC cleanup
  if self.stack_index > self.stack_max:
    self.stack_max = self.stack_index
  {.pop.}

proc pop*(self: var Frame): Value {.inline.} =
  {.push boundChecks: off, overflowChecks: off.}
  self.stack_index.dec()
  # Move value out of stack slot using raw copy (no retain - we're transferring ownership)
  copyMem(addr result, addr self.stack[self.stack_index], sizeof(Value))
  # Clear the slot using raw memory write to avoid =copy hook (no double-release)
  cast[ptr uint64](addr self.stack[self.stack_index])[] = 0
  {.pop.}

template pop2*(self: var Frame, to: var Value) =
  {.push boundChecks: off, overflowChecks: off.}
  self.stack_index.dec()
  # If to already has a managed value, release it first
  if isManaged(to):
    releaseManaged(to.raw)
  # Move value out of stack slot using raw copy (no retain)
  copyMem(addr to, addr self.stack[self.stack_index], sizeof(Value))
  # Clear the slot using raw memory write to avoid =copy hook
  cast[ptr uint64](addr self.stack[self.stack_index])[] = 0
  {.pop.}

proc push_call_base*(self: Frame) {.inline.} =
  assert self.stack_index > 0, "Cannot push call base without callee on stack"
  let base = self.stack_index - 1
  self.call_bases.push(base)

proc peek_call_base*(self: Frame): uint16 {.inline.} =
  self.call_bases.peek()

proc pop_call_base*(self: Frame): uint16 {.inline.} =
  self.call_bases.pop()

proc call_arg_count_from*(self: Frame, base: uint16): int {.inline.} =
  let stack_top = int(self.stack_index)
  let base_index = int(base)
  assert stack_top >= base_index + 1, "Call base exceeds stack height"
  stack_top - (base_index + 1)

proc call_arg_count*(self: Frame): int {.inline.} =
  self.call_arg_count_from(self.stack_index)

proc pop_call_arg_count*(self: Frame): int {.inline.} =
  let base = self.call_bases.pop()
  self.call_arg_count_from(base)
