## Frame operations: frame pool, CallBaseStack, stack push/pop.
## Included from core.nim — shares its scope.

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
