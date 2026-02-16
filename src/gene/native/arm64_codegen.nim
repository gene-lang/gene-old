## ARM64 (AArch64) Code Generator for Gene HIR
##
## Generates native ARM64 machine code from HIR.
## Uses AArch64 Procedure Call Standard (AAPCS64).
##
## Register allocation strategy (simple, no spilling for now):
##   - Parameters: x0-x7 (first 8 args)
##   - Return value: x0
##   - HIR registers are stored on the stack

import std/[tables, strformat]
import ./hir
import ./trampoline

proc c_fmod(x, y: cdouble): cdouble {.importc: "fmod", header: "<math.h>".}

type
  Arm64Reg* = enum
    X0 = 0, X1, X2, X3, X4, X5, X6, X7,
    X8, X9, X10, X11, X12, X13, X14, X15,
    X16, X17, X18, X19, X20, X21, X22, X23,
    X24, X25, X26, X27, X28, X29, X30, SP

  ## SIMD/FP D-registers for double-precision float
  DReg* = enum
    D0 = 0, D1, D2, D3, D4, D5, D6, D7

  FixupKind = enum
    FkB
    FkBl
    FkCbz

  CodeFixup = object
    offset: int
    target: HirBlockId
    kind: FixupKind

  CodeBuffer* = ref object
    code*: seq[byte]
    labels*: Table[HirBlockId, int]
    fixups*: seq[CodeFixup]

  CodegenContext* = ref object
    buf*: CodeBuffer
    fn*: HirFunction
    stackSize*: int32
    regOffsets*: Table[int32, int32]  # HIR reg -> stack offset from SP
    fnEntryOffset*: int
    recursiveCallFixups*: seq[int]
    callArgBaseOffset*: int32
    callArgSlots*: int32
    ctxSaveOffset*: int32

const
  INSN_STP_FP_LR = 0xA9BF7BFD'u32  # stp x29, x30, [sp, #-16]!
  INSN_MOV_FP_SP = 0x910003FD'u32  # mov x29, sp
  INSN_LDP_FP_LR = 0xA8C17BFD'u32  # ldp x29, x30, [sp], #16
  INSN_RET       = 0xD65F03C0'u32  # ret
  STRING_TAG_U64 = 0xFFFD_0000_0000_0000'u64
  PAYLOAD_MASK_U64 = 0x0000_FFFF_FFFF_FFFF'u64

proc newCodeBuffer*(): CodeBuffer =
  CodeBuffer(
    code: @[],
    labels: initTable[HirBlockId, int](),
    fixups: @[]
  )

proc emitU32*(buf: CodeBuffer, val: uint32) {.inline.} =
  buf.code.add(byte(val and 0xFF))
  buf.code.add(byte((val shr 8) and 0xFF))
  buf.code.add(byte((val shr 16) and 0xFF))
  buf.code.add(byte((val shr 24) and 0xFF))

proc currentOffset*(buf: CodeBuffer): int {.inline.} =
  buf.code.len

proc markLabel*(buf: CodeBuffer, blockId: HirBlockId) =
  buf.labels[blockId] = buf.currentOffset()

proc readU32(buf: CodeBuffer, offset: int): uint32 =
  uint32(buf.code[offset]) or
    (uint32(buf.code[offset + 1]) shl 8) or
    (uint32(buf.code[offset + 2]) shl 16) or
    (uint32(buf.code[offset + 3]) shl 24)

proc writeU32(buf: CodeBuffer, offset: int, val: uint32) =
  buf.code[offset] = byte(val and 0xFF)
  buf.code[offset + 1] = byte((val shr 8) and 0xFF)
  buf.code[offset + 2] = byte((val shr 16) and 0xFF)
  buf.code[offset + 3] = byte((val shr 24) and 0xFF)

proc resolveFixups*(buf: CodeBuffer) =
  for fixup in buf.fixups:
    if fixup.target notin buf.labels:
      raise newException(ValueError, fmt"Unresolved label: {fixup.target}")
    let targetOffset = buf.labels[fixup.target]
    let imm = int32((targetOffset - fixup.offset) div 4)
    case fixup.kind
    of FkB, FkBl:
      let imm26 = uint32(imm) and 0x03FF_FFFF'u32
      let instr = buf.readU32(fixup.offset)
      let patched = (instr and 0xFC00_0000'u32) or imm26
      buf.writeU32(fixup.offset, patched)
    of FkCbz:
      let imm19 = uint32(imm) and 0x7FFFF'u32
      let instr = buf.readU32(fixup.offset)
      let patched = (instr and 0xFF00_001F'u32) or (imm19 shl 5)
      buf.writeU32(fixup.offset, patched)

proc emitB*(buf: CodeBuffer, target: HirBlockId) =
  let offset = buf.currentOffset()
  buf.emitU32(0x1400_0000'u32)
  buf.fixups.add(CodeFixup(offset: offset, target: target, kind: FkB))

proc emitBl*(buf: CodeBuffer, target: HirBlockId) =
  let offset = buf.currentOffset()
  buf.emitU32(0x9400_0000'u32)
  buf.fixups.add(CodeFixup(offset: offset, target: target, kind: FkBl))

proc emitCbz*(buf: CodeBuffer, reg: Arm64Reg, target: HirBlockId) =
  let rt = uint32(ord(reg) and 0x1F)
  let offset = buf.currentOffset()
  buf.emitU32(0xB400_0000'u32 or rt)
  buf.fixups.add(CodeFixup(offset: offset, target: target, kind: FkCbz))

proc emitMovz*(buf: CodeBuffer, reg: Arm64Reg, imm16: uint16, shift: int32) =
  let hw = uint32(shift div 16) and 0x3
  let instr = 0xD280_0000'u32 or (hw shl 21) or (uint32(imm16) shl 5) or uint32(ord(reg) and 0x1F)
  buf.emitU32(instr)

proc emitMovk*(buf: CodeBuffer, reg: Arm64Reg, imm16: uint16, shift: int32) =
  let hw = uint32(shift div 16) and 0x3
  let instr = 0xF280_0000'u32 or (hw shl 21) or (uint32(imm16) shl 5) or uint32(ord(reg) and 0x1F)
  buf.emitU32(instr)

proc emitMovImm64*(buf: CodeBuffer, reg: Arm64Reg, imm: int64) =
  var value = uint64(imm)
  var first = true
  for shift in [0'i32, 16, 32, 48]:
    let part = uint16((value shr shift) and 0xFFFF)
    if part != 0'u16 or (value == 0 and first):
      if first:
        buf.emitMovz(reg, part, shift)
        first = false
      else:
        buf.emitMovk(reg, part, shift)

proc emitAddRegReg*(buf: CodeBuffer, dst, src1, src2: Arm64Reg) =
  let instr = 0x8B00_0000'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitAddRegImm*(buf: CodeBuffer, dst, src: Arm64Reg, imm: int32) =
  if imm < 0 or imm > 0xFFF:
    raise newException(ValueError, "ARM64 add immediate out of range")
  let imm12 = uint32(imm) and 0xFFF
  let instr = 0x9100_0000'u32 or
    (imm12 shl 10) or
    (uint32(ord(src) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitMovRegReg*(buf: CodeBuffer, dst, src: Arm64Reg) =
  buf.emitAddRegImm(dst, src, 0)

proc emitSubRegReg*(buf: CodeBuffer, dst, src1, src2: Arm64Reg) =
  let instr = 0xCB00_0000'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitAndRegReg*(buf: CodeBuffer, dst, src1, src2: Arm64Reg) =
  let instr = 0x8A00_0000'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitOrrRegReg*(buf: CodeBuffer, dst, src1, src2: Arm64Reg) =
  let instr = 0xAA00_0000'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitCmpRegReg*(buf: CodeBuffer, left, right: Arm64Reg) =
  let instr = 0xEB00_0000'u32 or
    (uint32(ord(right) and 0x1F) shl 16) or
    (uint32(ord(left) and 0x1F) shl 5) or
    31'u32
  buf.emitU32(instr)

proc emitCsetCond*(buf: CodeBuffer, dst: Arm64Reg, cond: uint32) =
  ## CSET is alias of CSINC with inverted condition (cond xor 1).
  let inv = cond xor 1
  let instr = 0x9A9F_07E0'u32 or (inv shl 12) or uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitCsetLe*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0xD)

proc emitCsetLt*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0xB)

proc emitCsetGe*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0xA)

proc emitCsetGt*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0xC)

proc emitCsetEq*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0x0)

proc emitCsetNe*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0x1)

proc emitMulRegReg*(buf: CodeBuffer, dst, src1, src2: Arm64Reg) =
  let instr = 0x9B00_7C00'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitSdivRegReg*(buf: CodeBuffer, dst, src1, src2: Arm64Reg) =
  let instr = 0x9AC0_0C00'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitMsubRegRegReg*(buf: CodeBuffer, dst, mul1, mul2, subFrom: Arm64Reg) =
  ## msub dst, mul1, mul2, subFrom
  ## dst = subFrom - (mul1 * mul2)
  let instr = 0x9B00_8000'u32 or
    (uint32(ord(mul2) and 0x1F) shl 16) or
    (uint32(ord(subFrom) and 0x1F) shl 10) or
    (uint32(ord(mul1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitNegReg*(buf: CodeBuffer, dst, src: Arm64Reg) =
  # neg dst, src  => sub dst, xzr, src
  let instr = 0xCB00_0000'u32 or
    (uint32(ord(src) and 0x1F) shl 16) or
    (31'u32 shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitSubSpImm*(buf: CodeBuffer, imm: int32) =
  let imm12 = uint32(imm) and 0xFFF
  let instr = 0xD100_0000'u32 or (imm12 shl 10) or (31'u32 shl 5) or 31'u32
  buf.emitU32(instr)

proc emitAddSpImm*(buf: CodeBuffer, imm: int32) =
  let imm12 = uint32(imm) and 0xFFF
  let instr = 0x9100_0000'u32 or (imm12 shl 10) or (31'u32 shl 5) or 31'u32
  buf.emitU32(instr)

# ==================== FP (Double) Instructions ====================

proc emitFLdr*(buf: CodeBuffer, dreg: DReg, offset: int32) =
  ## ldr Dd, [sp, #offset]  (FP double load, unsigned offset scaled by 8)
  if offset mod 8 != 0:
    raise newException(ValueError, "ARM64 FP LDR offset must be multiple of 8")
  let imm12 = uint32(offset div 8) and 0xFFF
  let instr = 0xFD400000'u32 or (imm12 shl 10) or (31'u32 shl 5) or uint32(ord(dreg) and 0x1F)
  buf.emitU32(instr)

proc emitFStr*(buf: CodeBuffer, dreg: DReg, offset: int32) =
  ## str Dd, [sp, #offset]  (FP double store, unsigned offset scaled by 8)
  if offset mod 8 != 0:
    raise newException(ValueError, "ARM64 FP STR offset must be multiple of 8")
  let imm12 = uint32(offset div 8) and 0xFFF
  let instr = 0xFD000000'u32 or (imm12 shl 10) or (31'u32 shl 5) or uint32(ord(dreg) and 0x1F)
  buf.emitU32(instr)

proc emitFadd*(buf: CodeBuffer, dst, src1, src2: DReg) =
  ## fadd Dd, Dn, Dm
  let instr = 0x1E602800'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitFsub*(buf: CodeBuffer, dst, src1, src2: DReg) =
  ## fsub Dd, Dn, Dm
  let instr = 0x1E603800'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitFmul*(buf: CodeBuffer, dst, src1, src2: DReg) =
  ## fmul Dd, Dn, Dm
  let instr = 0x1E600800'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitFdiv*(buf: CodeBuffer, dst, src1, src2: DReg) =
  ## fdiv Dd, Dn, Dm
  let instr = 0x1E601800'u32 or
    (uint32(ord(src2) and 0x1F) shl 16) or
    (uint32(ord(src1) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitFneg*(buf: CodeBuffer, dst, src: DReg) =
  ## fneg Dd, Dn
  let instr = 0x1E614000'u32 or
    (uint32(ord(src) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitFcmp*(buf: CodeBuffer, left, right: DReg) =
  ## fcmp Dn, Dm  (sets NZCV flags for float comparison)
  let instr = 0x1E602000'u32 or
    (uint32(ord(right) and 0x1F) shl 16) or
    (uint32(ord(left) and 0x1F) shl 5)
  buf.emitU32(instr)

proc emitFmovToGpr*(buf: CodeBuffer, dst: Arm64Reg, src: DReg) =
  ## fmov Xd, Dn  (bitcast float64 -> int64)
  let instr = 0x9E660000'u32 or
    (uint32(ord(src) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

proc emitFmovFromGpr*(buf: CodeBuffer, dst: DReg, src: Arm64Reg) =
  ## fmov Dd, Xn  (bitcast int64 -> float64)
  let instr = 0x9E670000'u32 or
    (uint32(ord(src) and 0x1F) shl 5) or
    uint32(ord(dst) and 0x1F)
  buf.emitU32(instr)

# Float comparison condition codes for CSET after FCMP
# (different from integer cmp for LT/LE to handle NaN correctly)
proc emitCsetFloatLe*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0x9)  # LS: C=0 || Z=1 (NaN-safe <=)

proc emitCsetFloatLt*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0x4)  # MI: N=1 (NaN-safe <)

proc emitCsetFloatGe*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0xA)  # GE: N==V (NaN-safe >=)

proc emitCsetFloatGt*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0xC)  # GT: Z=0 && N==V (NaN-safe >)

proc emitCsetFloatEq*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0x0)  # EQ: Z=1

proc emitCsetFloatNe*(buf: CodeBuffer, dst: Arm64Reg) =
  buf.emitCsetCond(dst, 0x1)  # NE: Z=0

# ==================== Integer Load/Store ====================

proc emitStrReg*(buf: CodeBuffer, reg: Arm64Reg, offset: int32) =
  if offset mod 8 != 0:
    raise newException(ValueError, "ARM64 STR offset must be multiple of 8")
  let imm12 = uint32(offset div 8) and 0xFFF
  let instr = 0xF900_0000'u32 or (imm12 shl 10) or (31'u32 shl 5) or uint32(ord(reg) and 0x1F)
  buf.emitU32(instr)

proc emitLdrReg*(buf: CodeBuffer, reg: Arm64Reg, offset: int32) =
  if offset mod 8 != 0:
    raise newException(ValueError, "ARM64 LDR offset must be multiple of 8")
  let imm12 = uint32(offset div 8) and 0xFFF
  let instr = 0xF940_0000'u32 or (imm12 shl 10) or (31'u32 shl 5) or uint32(ord(reg) and 0x1F)
  buf.emitU32(instr)

proc emitLdrRegBase*(buf: CodeBuffer, reg: Arm64Reg, base: Arm64Reg, offset: int32) =
  if offset mod 8 != 0:
    raise newException(ValueError, "ARM64 LDR offset must be multiple of 8")
  let imm12 = uint32(offset div 8) and 0xFFF
  let instr = 0xF940_0000'u32 or
    (imm12 shl 10) or
    (uint32(ord(base) and 0x1F) shl 5) or
    uint32(ord(reg) and 0x1F)
  buf.emitU32(instr)

proc emitBlr*(buf: CodeBuffer, reg: Arm64Reg) =
  let instr = 0xD63F_0000'u32 or (uint32(ord(reg) and 0x1F) shl 5)
  buf.emitU32(instr)

proc newCodegenContext*(fn: HirFunction): CodegenContext =
  result = CodegenContext(
    buf: newCodeBuffer(),
    fn: fn,
    regOffsets: initTable[int32, int32](),
    fnEntryOffset: 0,
    recursiveCallFixups: @[],
    callArgBaseOffset: 0,
    callArgSlots: 0,
    ctxSaveOffset: 0
  )

  for i in 0..<fn.regCount:
    result.regOffsets[i] = int32(i) * 8

  var maxCallArgs = 0
  for blk in fn.blocks:
    for op in blk.ops:
      if op.kind == HokCallVM and op.callVmArgs.len > maxCallArgs:
        maxCallArgs = op.callVmArgs.len
  result.callArgSlots = maxCallArgs.int32
  result.callArgBaseOffset = int32(fn.regCount) * 8
  result.ctxSaveOffset = result.callArgBaseOffset + result.callArgSlots * 8

  let baseSize = (fn.regCount + result.callArgSlots) * 8 + 8
  result.stackSize = ((baseSize + 15) div 16) * 16

proc regOffset*(ctx: CodegenContext, reg: HirReg): int32 =
  ctx.regOffsets[int32(reg)]

proc loadReg*(ctx: CodegenContext, dst: Arm64Reg, hirReg: HirReg) =
  ctx.buf.emitLdrReg(dst, ctx.regOffset(hirReg))

proc storeReg*(ctx: CodegenContext, hirReg: HirReg, src: Arm64Reg) =
  ctx.buf.emitStrReg(src, ctx.regOffset(hirReg))

proc loadRegF64*(ctx: CodegenContext, dst: DReg, hirReg: HirReg) =
  ## Load HIR register from stack into FP D-register
  ctx.buf.emitFLdr(dst, ctx.regOffset(hirReg))

proc storeRegF64*(ctx: CodegenContext, hirReg: HirReg, src: DReg) =
  ## Store FP D-register to HIR register on stack
  ctx.buf.emitFStr(src, ctx.regOffset(hirReg))

proc genOp*(ctx: CodegenContext, op: HirOp)

proc genConstI64*(ctx: CodegenContext, op: HirOp) =
  ctx.buf.emitMovImm64(X0, op.constI64)
  ctx.storeReg(op.dest, X0)

proc genAddI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitAddRegReg(X0, X0, X1)
  ctx.storeReg(op.dest, X0)

proc genSubI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitSubRegReg(X0, X0, X1)
  ctx.storeReg(op.dest, X0)

proc genMulI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitMulRegReg(X0, X0, X1)
  ctx.storeReg(op.dest, X0)

proc genDivI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitSdivRegReg(X0, X0, X1)
  ctx.storeReg(op.dest, X0)

proc genModI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitSdivRegReg(X2, X0, X1)
  ctx.buf.emitMsubRegRegReg(X0, X2, X1, X0)
  ctx.storeReg(op.dest, X0)

proc genNegI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.unaryArg)
  ctx.buf.emitNegReg(X0, X0)
  ctx.storeReg(op.dest, X0)

proc genLeI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitCmpRegReg(X0, X1)
  ctx.buf.emitCsetLe(X0)
  ctx.storeReg(op.dest, X0)

proc genLtI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitCmpRegReg(X0, X1)
  ctx.buf.emitCsetLt(X0)
  ctx.storeReg(op.dest, X0)

proc genGeI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitCmpRegReg(X0, X1)
  ctx.buf.emitCsetGe(X0)
  ctx.storeReg(op.dest, X0)

proc genGtI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitCmpRegReg(X0, X1)
  ctx.buf.emitCsetGt(X0)
  ctx.storeReg(op.dest, X0)

proc genEqI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitCmpRegReg(X0, X1)
  ctx.buf.emitCsetEq(X0)
  ctx.storeReg(op.dest, X0)

proc genNeI64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.binLeft)
  ctx.loadReg(X1, op.binRight)
  ctx.buf.emitCmpRegReg(X0, X1)
  ctx.buf.emitCsetNe(X0)
  ctx.storeReg(op.dest, X0)

proc genConstF64*(ctx: CodegenContext, op: HirOp) =
  ## Load float64 constant: movimm64 → GPR, fmov GPR → D-reg, store
  ctx.buf.emitMovImm64(X0, cast[int64](op.constF64))
  ctx.buf.emitFmovFromGpr(D0, X0)
  ctx.storeRegF64(op.dest, D0)

proc genAddF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFadd(D0, D0, D1)
  ctx.storeRegF64(op.dest, D0)

proc genSubF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFsub(D0, D0, D1)
  ctx.storeRegF64(op.dest, D0)

proc genMulF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFmul(D0, D0, D1)
  ctx.storeRegF64(op.dest, D0)

proc genDivF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFdiv(D0, D0, D1)
  ctx.storeRegF64(op.dest, D0)

proc genModF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitMovImm64(X8, cast[int64](cast[pointer](c_fmod)))
  ctx.buf.emitBlr(X8)
  ctx.storeRegF64(op.dest, D0)

proc genNegF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.unaryArg)
  ctx.buf.emitFneg(D0, D0)
  ctx.storeRegF64(op.dest, D0)

proc genLeF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFcmp(D0, D1)
  ctx.buf.emitCsetFloatLe(X0)
  ctx.storeReg(op.dest, X0)

proc genLtF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFcmp(D0, D1)
  ctx.buf.emitCsetFloatLt(X0)
  ctx.storeReg(op.dest, X0)

proc genGeF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFcmp(D0, D1)
  ctx.buf.emitCsetFloatGe(X0)
  ctx.storeReg(op.dest, X0)

proc genGtF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFcmp(D0, D1)
  ctx.buf.emitCsetFloatGt(X0)
  ctx.storeReg(op.dest, X0)

proc genEqF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFcmp(D0, D1)
  ctx.buf.emitCsetFloatEq(X0)
  ctx.storeReg(op.dest, X0)

proc genNeF64*(ctx: CodegenContext, op: HirOp) =
  ctx.loadRegF64(D0, op.binLeft)
  ctx.loadRegF64(D1, op.binRight)
  ctx.buf.emitFcmp(D0, D1)
  ctx.buf.emitCsetFloatNe(X0)
  ctx.storeReg(op.dest, X0)

proc genBr*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.brCond)
  ctx.buf.emitCbz(X0, op.brElse)
  ctx.buf.emitB(op.brThen)

proc genJump*(ctx: CodegenContext, op: HirOp) =
  ctx.buf.emitB(op.jumpTarget)

proc genRet*(ctx: CodegenContext, op: HirOp) =
  if ctx.fn.returnType == HtF64:
    # Load float, bitcast to int64 for uniform ABI return
    ctx.loadRegF64(D0, op.retValue)
    ctx.buf.emitFmovToGpr(X0, D0)
  else:
    ctx.loadReg(X0, op.retValue)
  ctx.buf.emitLdrReg(X19, ctx.ctxSaveOffset)
  if ctx.stackSize > 0:
    ctx.buf.emitAddSpImm(ctx.stackSize)
  ctx.buf.emitU32(INSN_LDP_FP_LR)
  ctx.buf.emitU32(INSN_RET)

proc genCall*(ctx: CodegenContext, op: HirOp) =
  const argRegs = [X1, X2, X3, X4, X5, X6, X7]
  if op.callArgs.len > argRegs.len:
    raise newException(ValueError, "Too many arguments for native call: " & $op.callArgs.len)
  ctx.buf.emitMovRegReg(X0, X19)
  for i in 0..<op.callArgs.len:
    ctx.loadReg(argRegs[i], op.callArgs[i])
  if op.callTarget != ctx.fn.name:
    raise newException(ValueError, "External native calls not supported: " & op.callTarget)
  let offset = ctx.buf.currentOffset()
  ctx.buf.emitU32(0x9400_0000'u32)  # bl placeholder
  ctx.recursiveCallFixups.add(offset)
  ctx.storeReg(op.dest, X0)

proc genCallVM*(ctx: CodegenContext, op: HirOp) =
  if op.callVmArgs.len > ctx.callArgSlots:
    raise newException(ValueError, "Too many arguments for trampoline call: " & $op.callVmArgs.len)

  for i in 0..<op.callVmArgs.len:
    ctx.loadReg(X0, op.callVmArgs[i])
    let offset = ctx.callArgBaseOffset + int32(i) * 8
    ctx.buf.emitStrReg(X0, offset)

  ctx.buf.emitMovRegReg(X0, X19)
  ctx.buf.emitMovImm64(X1, op.callVmDescIdx.int64)
  ctx.buf.emitAddRegImm(X2, SP, ctx.callArgBaseOffset)
  ctx.buf.emitMovImm64(X3, op.callVmArgs.len.int64)
  ctx.buf.emitLdrRegBase(X8, X19, NativeCtxOffsetTrampoline)
  ctx.buf.emitBlr(X8)

  ctx.storeReg(op.dest, X0)

proc genBoxString*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.unaryArg)
  ctx.buf.emitMovImm64(X1, cast[int64](STRING_TAG_U64))
  ctx.buf.emitOrrRegReg(X0, X0, X1)
  ctx.storeReg(op.dest, X0)

proc genUnboxString*(ctx: CodegenContext, op: HirOp) =
  ctx.loadReg(X0, op.unaryArg)
  ctx.buf.emitMovImm64(X1, cast[int64](PAYLOAD_MASK_U64))
  ctx.buf.emitAndRegReg(X0, X0, X1)
  ctx.storeReg(op.dest, X0)

proc genOp*(ctx: CodegenContext, op: HirOp) =
  case op.kind
  of HokConstI64: ctx.genConstI64(op)
  of HokConstF64: ctx.genConstF64(op)
  of HokAddI64: ctx.genAddI64(op)
  of HokSubI64: ctx.genSubI64(op)
  of HokMulI64: ctx.genMulI64(op)
  of HokDivI64: ctx.genDivI64(op)
  of HokModI64: ctx.genModI64(op)
  of HokNegI64: ctx.genNegI64(op)
  of HokAddF64: ctx.genAddF64(op)
  of HokSubF64: ctx.genSubF64(op)
  of HokMulF64: ctx.genMulF64(op)
  of HokDivF64: ctx.genDivF64(op)
  of HokModF64: ctx.genModF64(op)
  of HokNegF64: ctx.genNegF64(op)
  of HokLeI64: ctx.genLeI64(op)
  of HokLtI64: ctx.genLtI64(op)
  of HokGeI64: ctx.genGeI64(op)
  of HokGtI64: ctx.genGtI64(op)
  of HokEqI64: ctx.genEqI64(op)
  of HokNeI64: ctx.genNeI64(op)
  of HokLeF64: ctx.genLeF64(op)
  of HokLtF64: ctx.genLtF64(op)
  of HokGeF64: ctx.genGeF64(op)
  of HokGtF64: ctx.genGtF64(op)
  of HokEqF64: ctx.genEqF64(op)
  of HokNeF64: ctx.genNeF64(op)
  of HokBr: ctx.genBr(op)
  of HokJump: ctx.genJump(op)
  of HokRet: ctx.genRet(op)
  of HokCall: ctx.genCall(op)
  of HokCallVM: ctx.genCallVM(op)
  of HokBoxString: ctx.genBoxString(op)
  of HokUnboxString: ctx.genUnboxString(op)
  else:
    raise newException(ValueError, "Unsupported HIR op: " & $op.kind)

proc genPrologue*(ctx: CodegenContext) =
  ctx.buf.emitU32(INSN_STP_FP_LR)
  ctx.buf.emitU32(INSN_MOV_FP_SP)
  if ctx.stackSize > 0:
    ctx.buf.emitSubSpImm(ctx.stackSize)

  # Store parameters to stack slots
  # All args arrive as int64 (uniform ABI). F64 params are bitcast in prologue.
  ctx.buf.emitStrReg(X19, ctx.ctxSaveOffset)
  ctx.buf.emitMovRegReg(X19, X0)
  const argRegs = [X1, X2, X3, X4, X5, X6, X7]
  let count = min(ctx.fn.params.len, argRegs.len)
  for i in 0..<count:
    if ctx.fn.params[i].typ == HtF64:
      # Bitcast int64 → float64 and store as double
      ctx.buf.emitFmovFromGpr(D0, argRegs[i])
      ctx.buf.emitFStr(D0, int32(i) * 8)
    else:
      ctx.buf.emitStrReg(argRegs[i], int32(i) * 8)

proc genBlock*(ctx: CodegenContext, blk: HirBlock) =
  ctx.buf.markLabel(blk.id)
  for op in blk.ops:
    ctx.genOp(op)

proc generateCode*(fn: HirFunction): seq[byte] =
  let ctx = newCodegenContext(fn)
  ctx.fnEntryOffset = 0
  ctx.genPrologue()
  for blk in fn.blocks:
    ctx.genBlock(blk)
  ctx.buf.resolveFixups()
  for offset in ctx.recursiveCallFixups:
    let imm = int32((ctx.fnEntryOffset - offset) div 4)
    let imm26 = uint32(imm) and 0x03FF_FFFF'u32
    let instr = ctx.buf.readU32(offset)
    let patched = (instr and 0xFC00_0000'u32) or imm26
    ctx.buf.writeU32(offset, patched)
  result = ctx.buf.code

proc disassemble*(code: seq[byte]): string =
  result = "Generated code (" & $code.len & " bytes):\n"
  for i, b in code:
    if i mod 16 == 0:
      if i > 0: result &= "\n"
      result &= fmt"{i:04x}: "
    result &= fmt"{b:02x} "
  result &= "\n"
