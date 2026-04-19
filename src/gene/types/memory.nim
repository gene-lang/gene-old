## GC infrastructure: NaN boxing constants, destroy procs, retain/release,
## lifecycle hooks (=destroy, =copy, =sink, =default).
## Included from type_defs.nim — shares its scope.
##
## Shared-RC publication invariant:
## - Any managed value observed with `shared == true` must have been published
##   by `(freeze v)` or bootstrap publication, with the header bit written
##   under the same publication barrier as the pointer store.
## - Readers on other threads may only dereference managed values reached
##   through `shared == true` pointers, or through the same-thread owned heap.
## - Passing a managed value across threads while `shared == false` is a bug;
##   debug retain/release assertions and the shared-heap regression test are
##   expected to catch that violation.

# Global list of scheduler poll callbacks - extensions register handlers here
var scheduler_callbacks*: seq[SchedulerCallback] = @[]

var repl_on_throw_callback*: ReplOnThrowCallback = nil

proc register_scheduler_callback*(callback: SchedulerCallback) =
  ## Register a callback to be called during run_forever scheduler loop.
  ## Extensions like HTTP use this to process pending requests.
  scheduler_callbacks.add(callback)

#################### GC Infrastructure (must be after type defs, before Value usage) #################

# NaN Boxing constants
const PAYLOAD_MASK* = 0x0000_FFFF_FFFF_FFFFu64
const TAG_SHIFT* = 48
const RC_SHARED_BIT = 0b0000_0010'u8

# Primary type tags in NaN space (reorganized for GC)
# DESIGN: All managed types (need ref-counting) have tags >= 0xFFF8
#         All non-managed types (immediate/global) have tags < 0xFFF8

# Non-managed types (< 0xFFF8)
const SPECIAL_TAG*   = 0xFFF1_0000_0000_0000u64
const SMALL_INT_TAG* = 0xFFF2_0000_0000_0000u64
const SYMBOL_TAG*    = 0xFFF3_0000_0000_0000u64
const POINTER_TAG*   = 0xFFF4_0000_0000_0000u64
const BYTES_TAG*     = 0xFFF5_0000_0000_0000u64  # 1-5 bytes immediate
const BYTES6_TAG*    = 0xFFF6_0000_0000_0000u64  # 6 bytes immediate

# BYTES_TAG layout: [tag:16][size:3][unused:5][data:40]
const BYTES_SIZE_SHIFT* = 45
const BYTES_SIZE_MASK*  = 0x0000_E000_0000_0000u64  # bits 47-45
const BYTES_DATA_MASK*  = 0x0000_00FF_FFFF_FFFFu64  # bits 39-0

# Managed types (>= 0xFFF8)
const ARRAY_TAG*     = 0xFFF8_0000_0000_0000u64
const MAP_TAG*       = 0xFFF9_0000_0000_0000u64
const INSTANCE_TAG*  = 0xFFFA_0000_0000_0000u64
const GENE_TAG*      = 0xFFFB_0000_0000_0000u64
const REF_TAG*       = 0xFFFC_0000_0000_0000u64
const STRING_TAG*    = 0xFFFD_0000_0000_0000u64

# Fast managed check
template isManaged*(v: Value): bool =
  ## Returns true if value is a managed (heap-allocated, ref-counted) type
  ## All managed types have tags >= 0xFFF8
  (v.raw and 0xFFF8_0000_0000_0000'u64) == 0xFFF8_0000_0000_0000'u64

# Destroy helpers
template destroyAndDealloc[T](p: ptr T) =
  ## Safely destroy and deallocate a heap object
  if p != nil:
    reset(p[])   # Run Nim destructors on all fields
    dealloc(p)   # Free memory

proc destroy_string(s: ptr String) =
  destroyAndDealloc(s)

proc destroy_array(arr: ptr ArrayObj) =
  destroyAndDealloc(arr)

proc destroy_map(m: ptr MapObj) =
  destroyAndDealloc(m)

proc destroy_gene(g: ptr Gene) =
  destroyAndDealloc(g)

proc destroy_instance(inst: ptr InstanceObj) =
  destroyAndDealloc(inst)

proc destroy_reference(ref_obj: ptr Reference) =
  destroyAndDealloc(ref_obj)

when defined(phase1_rc_branch_probe):
  type RcBranchOp* = enum
    RcPlainInc,
    RcAtomicInc,
    RcPlainDec,
    RcAtomicDec

  var rcBranchProbeEnabled {.global.} = true
  var rcBranchCounts {.global.}: array[RcBranchOp, int]

  proc resetRcBranchProbe*() =
    for op in RcBranchOp:
      rcBranchCounts[op] = 0

  proc rcBranchProbeCount*(op: RcBranchOp): int =
    rcBranchCounts[op]

  proc setRcBranchProbeEnabled*(enabled: bool) =
    rcBranchProbeEnabled = enabled

  template recordRcBranch(op: static RcBranchOp) =
    if rcBranchProbeEnabled:
      rcBranchCounts[op].inc()
else:
  template recordRcBranch(op: untyped) =
    discard

template incRc(hdr, shared: untyped) =
  if shared:
    recordRcBranch(RcAtomicInc)
    atomicInc(hdr.ref_count)
  else:
    recordRcBranch(RcPlainInc)
    hdr.ref_count.inc()

template decRc(hdr, shared: untyped): int =
  (block:
    if shared:
      recordRcBranch(RcAtomicDec)
      atomicDec(hdr.ref_count)
    else:
      recordRcBranch(RcPlainDec)
      let old_count = hdr.ref_count
      hdr.ref_count.dec()
      old_count)

# Core GC operations
proc retainManaged*(raw: uint64) {.gcsafe.} =
  ## Increment reference count for a managed value
  if raw == 0:
    return

  let tag = raw shr 48
  case tag:
    of 0xFFF8:  # ARRAY_TAG
      let arr = cast[ptr ArrayObj](raw and PAYLOAD_MASK)
      if arr != nil:
        incRc(arr, (arr.flags and RC_SHARED_BIT) != 0)
    of 0xFFF9:  # MAP_TAG
      let m = cast[ptr MapObj](raw and PAYLOAD_MASK)
      if m != nil:
        incRc(m, (m.flags and RC_SHARED_BIT) != 0)
    of 0xFFFA:  # INSTANCE_TAG
      let inst = cast[ptr InstanceObj](raw and PAYLOAD_MASK)
      if inst != nil:
        incRc(inst, (inst.flags and RC_SHARED_BIT) != 0)
    of 0xFFFB:  # GENE_TAG
      let g = cast[ptr Gene](raw and PAYLOAD_MASK)
      if g != nil:
        incRc(g, (g.flags and RC_SHARED_BIT) != 0)
    of 0xFFFC:  # REF_TAG
      let ref_obj = cast[ptr Reference](raw and PAYLOAD_MASK)
      if ref_obj != nil:
        incRc(ref_obj, (ref_obj.flags and RC_SHARED_BIT) != 0)
    of 0xFFFD:  # STRING_TAG
      let s = cast[ptr String](raw and PAYLOAD_MASK)
      if s != nil:
        incRc(s, (s.flags and RC_SHARED_BIT) != 0)
    else:
      discard

proc releaseManaged*(raw: uint64) {.gcsafe.} =
  ## Decrement reference count, destroy at 0
  ## CRITICAL: Must validate pointer before dereferencing to avoid SIGSEGV on garbage
  if raw == 0:
    return

  let tag = raw shr 48

  # Validate tag is exactly in managed range
  if tag < 0xFFF8 or tag > 0xFFFD:
    return

  # Validate payload is not null
  let payload = raw and PAYLOAD_MASK
  if payload == 0:
    return

  # Validate pointer looks reasonable (not obviously garbage)
  # Check if it's aligned (pointers should be 8-byte aligned on most platforms)
  if (payload and 0x7) != 0:
    return  # Not 8-byte aligned, likely garbage

  # We cannot safely validate ref_count without dereferencing,
  # and try-except doesn't catch SIGSEGV in Nim.
  # Our best defense is tag + alignment validation above.
  # Unfortunately, this means we may still crash on cleverly-aligned garbage.

  case tag:
    of 0xFFF8:  # ARRAY_TAG
      let arr = cast[ptr ArrayObj](payload)
      let old_count = decRc(arr, (arr.flags and RC_SHARED_BIT) != 0)
      if old_count == 1:
        destroy_array(arr)
    of 0xFFF9:  # MAP_TAG
      let m = cast[ptr MapObj](payload)
      let old_count = decRc(m, (m.flags and RC_SHARED_BIT) != 0)
      if old_count == 1:
        destroy_map(m)
    of 0xFFFA:  # INSTANCE_TAG
      let inst = cast[ptr InstanceObj](payload)
      let old_count = decRc(inst, (inst.flags and RC_SHARED_BIT) != 0)
      if old_count == 1:
        destroy_instance(inst)
    of 0xFFFB:  # GENE_TAG
      let g = cast[ptr Gene](payload)
      let old_count = decRc(g, (g.flags and RC_SHARED_BIT) != 0)
      if old_count == 1:
        destroy_gene(g)
    of 0xFFFC:  # REF_TAG
      let ref_obj = cast[ptr Reference](payload)
      let old_count = decRc(ref_obj, (ref_obj.flags and RC_SHARED_BIT) != 0)
      if old_count == 1:
        destroy_reference(ref_obj)
    of 0xFFFD:  # STRING_TAG
      let s = cast[ptr String](payload)
      let old_count = decRc(s, (s.flags and RC_SHARED_BIT) != 0)
      if old_count == 1:
        destroy_string(s)
    else:
      discard

# Lifecycle hooks for automatic GC

proc `=default`*(v: var Value) {.inline.} =
  ## Default constructor - initializes all Values to NIL
  ## This ensures no uninitialized garbage, making =copy safe
  v.raw = 0

proc `=destroy`*(v: Value) =
  ## Called when Value goes out of scope
  ## Decrements ref count for managed types
  if isManaged(v):
    releaseManaged(v.raw)

proc `=copy`*(dest: var Value; src: Value) =
  ## Called on assignment: dest = src
  ## Must destroy old dest, copy bits, then retain new value

  # Release old dest value if it's a managed type
  if isManaged(dest):
    releaseManaged(dest.raw)

  # Bitwise copy
  dest.raw = src.raw

  # Retain new value (if managed)
  if isManaged(src):
    retainManaged(src.raw)

proc `=sink`*(dest: var Value; src: Value) =
  ## Called on move/sink: dest = move(src)
  ## Transfers ownership without retain/release

  # Release old dest value if it's a managed type
  if isManaged(dest):
    releaseManaged(dest.raw)

  # Transfer ownership (no retain - src won't be destroyed)
  dest.raw = src.raw
