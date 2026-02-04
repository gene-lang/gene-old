## HIR (High-level Intermediate Representation) for Gene Native Code Generation
##
## SSA-form typed IR for native compilation. Each value is assigned exactly once.
## Designed for typed Gene functions where type information enables efficient codegen.
##
## Example HIR for fib(n: Int) -> Int:
##   function @fib(%0: i64) -> i64 {
##   entry:
##     %1 = le.i64 %0, 1
##     br %1, then, else
##   then:
##     ret %0
##   else:
##     %2 = sub.i64 %0, 1
##     %3 = call @fib(%2) : i64
##     %4 = sub.i64 %0, 2
##     %5 = call @fib(%4) : i64
##     %6 = add.i64 %3, %5
##     ret %6
##   }

import std/[tables, strformat, strutils, sequtils]

type
  ## HIR type tags - primitive types that can be represented in registers
  HirType* = enum
    HtVoid     ## No value (for statements)
    HtBool     ## Boolean (stored as i64, 0 or 1)
    HtI64      ## 64-bit signed integer
    HtF64      ## 64-bit floating point
    HtPtr      ## Raw pointer (for objects, arrays, etc.)
    HtValue    ## NaN-boxed Gene Value (for dynamic operations)

  ## Virtual register - SSA value reference
  HirReg* = distinct int32

  ## Block label
  HirBlockId* = distinct int32

  ## Operation kinds - core operations for native codegen
  HirOpKind* = enum
    # Constants and moves
    HokConstI64     ## %r = const.i64 <value>
    HokConstF64     ## %r = const.f64 <value>
    HokConstBool    ## %r = const.bool <value>
    HokCopy         ## %r = copy %src

    # Integer arithmetic
    HokAddI64       ## %r = add.i64 %a, %b
    HokSubI64       ## %r = sub.i64 %a, %b
    HokMulI64       ## %r = mul.i64 %a, %b
    HokDivI64       ## %r = div.i64 %a, %b
    HokNegI64       ## %r = neg.i64 %a

    # Float arithmetic
    HokAddF64       ## %r = add.f64 %a, %b
    HokSubF64       ## %r = sub.f64 %a, %b
    HokMulF64       ## %r = mul.f64 %a, %b
    HokDivF64       ## %r = div.f64 %a, %b
    HokNegF64       ## %r = neg.f64 %a

    # Comparisons (produce HtBool)
    HokLeI64        ## %r = le.i64 %a, %b  (a <= b)
    HokLtI64        ## %r = lt.i64 %a, %b  (a < b)
    HokGeI64        ## %r = ge.i64 %a, %b  (a >= b)
    HokGtI64        ## %r = gt.i64 %a, %b  (a > b)
    HokEqI64        ## %r = eq.i64 %a, %b  (a == b)
    HokNeI64        ## %r = ne.i64 %a, %b  (a != b)

    # Control flow
    HokBr           ## br %cond, then_block, else_block
    HokJump         ## jump block
    HokRet          ## ret %value
    HokRetVoid      ## ret (no value)

    # Function calls
    HokCall         ## %r = call @fn(%args...) : type
    HokCallIndirect ## %r = call %fn_ptr(%args...) : type

    # SSA Phi nodes (for joining control flow)
    HokPhi          ## %r = phi [%a, block1], [%b, block2]

    # NaN-boxing operations (for VM interop)
    HokBoxI64       ## %r = box.i64 %val  (int64 -> Value)
    HokBoxF64       ## %r = box.f64 %val  (float64 -> Value)
    HokBoxBool      ## %r = box.bool %val (bool -> Value)
    HokUnboxI64     ## %r = unbox.i64 %val (Value -> int64)
    HokUnboxF64     ## %r = unbox.f64 %val (Value -> float64)
    HokUnboxBool    ## %r = unbox.bool %val (Value -> bool)

    # Dynamic fallback (call VM for complex operations)
    HokVmCall       ## %r = vmcall <op>, %args...

  ## A single HIR operation
  HirOp* = object
    dest*: HirReg            ## Destination register (or -1 for control flow)
    destType*: HirType       ## Type of destination
    case kind*: HirOpKind
    of HokConstI64:
      constI64*: int64
    of HokConstF64:
      constF64*: float64
    of HokConstBool:
      constBool*: bool
    of HokCopy, HokNegI64, HokNegF64, HokBoxI64, HokBoxF64, HokBoxBool,
       HokUnboxI64, HokUnboxF64, HokUnboxBool:
      unaryArg*: HirReg
    of HokAddI64, HokSubI64, HokMulI64, HokDivI64,
       HokAddF64, HokSubF64, HokMulF64, HokDivF64,
       HokLeI64, HokLtI64, HokGeI64, HokGtI64, HokEqI64, HokNeI64:
      binLeft*: HirReg
      binRight*: HirReg
    of HokBr:
      brCond*: HirReg
      brThen*: HirBlockId
      brElse*: HirBlockId
    of HokJump:
      jumpTarget*: HirBlockId
    of HokRet:
      retValue*: HirReg
    of HokRetVoid:
      discard
    of HokCall:
      callTarget*: string      ## Function name
      callArgs*: seq[HirReg]
      callRetType*: HirType
    of HokCallIndirect:
      callIndirectFn*: HirReg
      callIndirectArgs*: seq[HirReg]
      callIndirectRetType*: HirType
    of HokPhi:
      phiSources*: seq[tuple[reg: HirReg, fromBlock: HirBlockId]]
    of HokVmCall:
      vmCallOp*: string
      vmCallArgs*: seq[HirReg]

  ## A basic block in HIR
  HirBlock* = object
    id*: HirBlockId
    name*: string             ## e.g., "entry", "then", "else"
    ops*: seq[HirOp]
    predecessors*: seq[HirBlockId]
    successors*: seq[HirBlockId]

  ## A complete HIR function
  HirFunction* = object
    name*: string
    params*: seq[tuple[name: string, typ: HirType]]
    returnType*: HirType
    blocks*: seq[HirBlock]
    regCount*: int32          ## Total number of registers used
    isNativeEligible*: bool   ## True if function can be fully native

  ## Native function pointer (for compiled code)
  NativeFnPtr* = proc(args: ptr UncheckedArray[int64], argc: int32): int64 {.cdecl.}

  ## Compiled native function entry
  NativeFunction* = object
    name*: string
    hir*: HirFunction
    machineCode*: seq[byte]
    entryPoint*: NativeFnPtr
    boxedWrapper*: NativeFnPtr  ## Wrapper that handles Value boxing/unboxing

# ==================== Constructors ====================

proc newHirReg*(id: int32): HirReg {.inline.} =
  HirReg(id)

proc newHirBlockId*(id: int32): HirBlockId {.inline.} =
  HirBlockId(id)

proc `$`*(r: HirReg): string =
  "%" & $int32(r)

proc `$`*(b: HirBlockId): string =
  "L" & $int32(b)

proc `==`*(a, b: HirReg): bool {.borrow.}
proc `==`*(a, b: HirBlockId): bool {.borrow.}

# ==================== HirFunction Builder ====================

type
  HirBuilder* = ref object
    fn*: HirFunction
    currentBlock*: HirBlockId
    nextReg*: int32
    blockMap*: Table[string, HirBlockId]

proc newHirBuilder*(name: string, returnType: HirType): HirBuilder =
  result = HirBuilder(
    fn: HirFunction(name: name, returnType: returnType),
    currentBlock: newHirBlockId(-1),
    nextReg: 0,
  )

proc addParam*(b: HirBuilder, name: string, typ: HirType): HirReg =
  ## Add a parameter and return its register
  let reg = newHirReg(b.nextReg)
  b.nextReg.inc
  b.fn.params.add((name: name, typ: typ))
  result = reg

proc newBlock*(b: HirBuilder, name: string): HirBlockId =
  ## Create a new basic block
  let id = newHirBlockId(b.fn.blocks.len.int32)
  b.fn.blocks.add(HirBlock(id: id, name: name))
  b.blockMap[name] = id
  result = id

proc setCurrentBlock*(b: HirBuilder, blockId: HirBlockId) =
  b.currentBlock = blockId

proc currentBlockRef(b: HirBuilder): var HirBlock =
  b.fn.blocks[int32(b.currentBlock)]

proc allocReg*(b: HirBuilder): HirReg =
  result = newHirReg(b.nextReg)
  b.nextReg.inc

proc emit(b: HirBuilder, op: HirOp) =
  b.currentBlockRef.ops.add(op)

# ==================== Emit Operations ====================

proc emitConstI64*(b: HirBuilder, value: int64): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokConstI64, dest: result, destType: HtI64, constI64: value))

proc emitConstBool*(b: HirBuilder, value: bool): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokConstBool, dest: result, destType: HtBool, constBool: value))

proc emitAddI64*(b: HirBuilder, left, right: HirReg): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokAddI64, dest: result, destType: HtI64, binLeft: left, binRight: right))

proc emitSubI64*(b: HirBuilder, left, right: HirReg): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokSubI64, dest: result, destType: HtI64, binLeft: left, binRight: right))

proc emitLeI64*(b: HirBuilder, left, right: HirReg): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokLeI64, dest: result, destType: HtBool, binLeft: left, binRight: right))

proc emitBr*(b: HirBuilder, cond: HirReg, thenBlock, elseBlock: HirBlockId) =
  b.emit(HirOp(kind: HokBr, dest: newHirReg(-1), destType: HtVoid,
               brCond: cond, brThen: thenBlock, brElse: elseBlock))

proc emitJump*(b: HirBuilder, target: HirBlockId) =
  b.emit(HirOp(kind: HokJump, dest: newHirReg(-1), destType: HtVoid, jumpTarget: target))

proc emitRet*(b: HirBuilder, value: HirReg) =
  b.emit(HirOp(kind: HokRet, dest: newHirReg(-1), destType: HtVoid, retValue: value))

proc emitCall*(b: HirBuilder, target: string, args: seq[HirReg], retType: HirType): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokCall, dest: result, destType: retType,
               callTarget: target, callArgs: args, callRetType: retType))

proc emitBoxI64*(b: HirBuilder, value: HirReg): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokBoxI64, dest: result, destType: HtValue, unaryArg: value))

proc emitUnboxI64*(b: HirBuilder, value: HirReg): HirReg =
  result = b.allocReg()
  b.emit(HirOp(kind: HokUnboxI64, dest: result, destType: HtI64, unaryArg: value))

proc finalize*(b: HirBuilder): HirFunction =
  b.fn.regCount = b.nextReg
  # TODO: Compute predecessors/successors for each block
  result = b.fn

# ==================== Pretty Printing ====================

proc `$`*(op: HirOp): string =
  case op.kind
  of HokConstI64:
    result = fmt"{op.dest} = const.i64 {op.constI64}"
  of HokConstF64:
    result = fmt"{op.dest} = const.f64 {op.constF64}"
  of HokConstBool:
    result = fmt"{op.dest} = const.bool {op.constBool}"
  of HokCopy:
    result = fmt"{op.dest} = copy {op.unaryArg}"
  of HokAddI64:
    result = fmt"{op.dest} = add.i64 {op.binLeft}, {op.binRight}"
  of HokSubI64:
    result = fmt"{op.dest} = sub.i64 {op.binLeft}, {op.binRight}"
  of HokMulI64:
    result = fmt"{op.dest} = mul.i64 {op.binLeft}, {op.binRight}"
  of HokDivI64:
    result = fmt"{op.dest} = div.i64 {op.binLeft}, {op.binRight}"
  of HokNegI64:
    result = fmt"{op.dest} = neg.i64 {op.unaryArg}"
  of HokAddF64:
    result = fmt"{op.dest} = add.f64 {op.binLeft}, {op.binRight}"
  of HokSubF64:
    result = fmt"{op.dest} = sub.f64 {op.binLeft}, {op.binRight}"
  of HokMulF64:
    result = fmt"{op.dest} = mul.f64 {op.binLeft}, {op.binRight}"
  of HokDivF64:
    result = fmt"{op.dest} = div.f64 {op.binLeft}, {op.binRight}"
  of HokNegF64:
    result = fmt"{op.dest} = neg.f64 {op.unaryArg}"
  of HokLeI64:
    result = fmt"{op.dest} = le.i64 {op.binLeft}, {op.binRight}"
  of HokLtI64:
    result = fmt"{op.dest} = lt.i64 {op.binLeft}, {op.binRight}"
  of HokGeI64:
    result = fmt"{op.dest} = ge.i64 {op.binLeft}, {op.binRight}"
  of HokGtI64:
    result = fmt"{op.dest} = gt.i64 {op.binLeft}, {op.binRight}"
  of HokEqI64:
    result = fmt"{op.dest} = eq.i64 {op.binLeft}, {op.binRight}"
  of HokNeI64:
    result = fmt"{op.dest} = ne.i64 {op.binLeft}, {op.binRight}"
  of HokBr:
    result = fmt"br {op.brCond}, {op.brThen}, {op.brElse}"
  of HokJump:
    result = fmt"jump {op.jumpTarget}"
  of HokRet:
    result = fmt"ret {op.retValue}"
  of HokRetVoid:
    result = "ret"
  of HokCall:
    let args = op.callArgs.mapIt($it).join(", ")
    result = fmt"{op.dest} = call @{op.callTarget}({args}) : {op.callRetType}"
  of HokCallIndirect:
    let args = op.callIndirectArgs.mapIt($it).join(", ")
    result = fmt"{op.dest} = call {op.callIndirectFn}({args}) : {op.callIndirectRetType}"
  of HokPhi:
    var sources: seq[string]
    for src in op.phiSources:
      sources.add("[" & $src.reg & ", " & $src.fromBlock & "]")
    result = $op.dest & " = phi " & sources.join(", ")
  of HokBoxI64:
    result = fmt"{op.dest} = box.i64 {op.unaryArg}"
  of HokBoxF64:
    result = fmt"{op.dest} = box.f64 {op.unaryArg}"
  of HokBoxBool:
    result = fmt"{op.dest} = box.bool {op.unaryArg}"
  of HokUnboxI64:
    result = fmt"{op.dest} = unbox.i64 {op.unaryArg}"
  of HokUnboxF64:
    result = fmt"{op.dest} = unbox.f64 {op.unaryArg}"
  of HokUnboxBool:
    result = fmt"{op.dest} = unbox.bool {op.unaryArg}"
  of HokVmCall:
    let args = op.vmCallArgs.mapIt($it).join(", ")
    result = fmt"{op.dest} = vmcall {op.vmCallOp}({args})"

proc `$`*(blk: HirBlock): string =
  result = fmt"{blk.name}:  ; {blk.id}" & "\n"
  for op in blk.ops:
    result &= "    " & $op & "\n"

proc `$`*(fn: HirFunction): string =
  let params = fn.params.mapIt(fmt"{it.name}: {it.typ}").join(", ")
  result = fmt"function @{fn.name}({params}) -> {fn.returnType}" & " {\n"
  for blk in fn.blocks:
    result &= $blk
  result &= "}\n"

# ==================== Example: Build fib HIR ====================

proc buildFibHir*(): HirFunction =
  ## Build HIR for: (fn fib [n: Int] -> Int ...)
  ## Used for testing and documentation
  let b = newHirBuilder("fib", HtI64)

  # Parameter: n is register %0
  let n = b.addParam("n", HtI64)

  # Create blocks
  let entry = b.newBlock("entry")
  let thenBlock = b.newBlock("then")
  let elseBlock = b.newBlock("else")

  # entry block
  b.setCurrentBlock(entry)
  let one = b.emitConstI64(1)
  let cmp = b.emitLeI64(n, one)
  b.emitBr(cmp, thenBlock, elseBlock)

  # then block: return n
  b.setCurrentBlock(thenBlock)
  b.emitRet(n)

  # else block: return fib(n-1) + fib(n-2)
  b.setCurrentBlock(elseBlock)
  let nMinus1 = b.emitSubI64(n, one)
  let fib1 = b.emitCall("fib", @[nMinus1], HtI64)
  let two = b.emitConstI64(2)
  let nMinus2 = b.emitSubI64(n, two)
  let fib2 = b.emitCall("fib", @[nMinus2], HtI64)
  let sum = b.emitAddI64(fib1, fib2)
  b.emitRet(sum)

  result = b.finalize()

