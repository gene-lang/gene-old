import std/[strformat, strutils, sequtils]
import ./types

type
  AirOpcode* = enum
    OpNop
    OpConst
    OpConstNil
    OpConstTrue
    OpConstFalse
    OpPop
    OpDup
    OpSwap
    OpOver
    OpLoadLocal
    OpStoreLocal
    OpLoadUpvalue
    OpStoreUpvalue
    OpLoadSelf
    OpLoadSuper
    OpTypeof
    OpIsType
    OpRangeNew
    OpEnumNew
    OpEnumAdd
    OpAdd
    OpSub
    OpMul
    OpDiv
    OpMod
    OpPow
    OpNeg
    OpCmpEq
    OpCmpNe
    OpCmpLt
    OpCmpLe
    OpCmpGt
    OpCmpGe
    OpLogAnd
    OpLogOr
    OpLogNot
    OpJump
    OpBrTrue
    OpBrFalse
    OpReturn
    OpThrow
    OpTryBegin
    OpTryEnd
    OpCatchBegin
    OpCatchEnd
    OpFinallyBegin
    OpFinallyEnd
    OpRethrow
    OpFnNew
    OpClosureNew
    OpCall
    OpCallKw
    OpCallDynamic
    OpTailCall
    OpCallMethod
    OpCallMethodKw
    OpCallSuper
    OpCallSuperKw
    OpCallMacro
    OpCallerEval
    OpYield
    OpResume
    OpArrNew
    OpArrPush
    OpArrSpread
    OpArrEnd
    OpMapNew
    OpMapSet
    OpMapSetDynamic
    OpMapSpread
    OpMapEnd
    OpGeneNew
    OpGeneSetType
    OpGeneSetProp
    OpGeneSetPropDynamic
    OpGeneAddChild
    OpGeneAddSpread
    OpGeneEnd
    OpClassNew
    OpClassExtends
    OpMethodDef
    OpCtorDef
    OpPropDef
    OpDecoratorApply
    OpInterceptEnter
    OpInterceptExit
    OpImport
    OpExport
    OpNsEnter
    OpNsExit
    OpGetMember
    OpGetMemberNil
    OpGetMemberDefault
    OpGetMemberDynamic
    OpSetMember
    OpSetMemberDynamic
    OpGetChild
    OpGetChildDynamic
    OpAsyncBegin
    OpAsyncEnd
    OpAwait
    OpFutureWrap
    OpThreadSpawn
    OpTaskScopeEnter
    OpTaskSpawn
    OpTaskJoin
    OpTaskCancel
    OpTaskDeadline
    OpCapEnter
    OpCapExit
    OpCapAssert
    OpQuotaSet
    OpQuotaCheck
    OpCheckpointHint
    OpStateSave
    OpStateRestore
    OpToolPrep
    OpToolCall
    OpToolAwait
    OpToolResultUnwrap
    OpToolRetry
    OpDetSeed
    OpDetRand
    OpDetNow
    OpTraceEmit
    OpAuditEmit
    OpDiagEmit
    # Implementation-support ops
    OpLoadGlobal
    OpStoreGlobal
    OpIterInit
    OpIterHasNext
    OpIterNext
    OpHalt

  AirInst* = object
    op*: AirOpcode
    mode*: uint8
    a*: uint8
    b*: uint32
    c*: uint32
    d*: uint32

  FunctionFlag* = enum
    FFlagAsync
    FFlagGenerator
    FFlagMacroLike
    FFlagMethod
    FFlagHasTry

  AirParam* = object
    name*: string
    typeAnn*: string

  AirFunction* = ref object
    id*: int
    name*: string
    flags*: set[FunctionFlag]
    arity*: int
    params*: seq[AirParam]
    localCount*: int
    localSymbols*: seq[int]
    upvalueSymbols*: seq[int]
    effectProfileId*: int
    capabilityProfileId*: int
    matcherRef*: int
    code*: seq[AirInst]

  EffectProfile* = object
    name*: string
    capabilities*: seq[string]

  ToolSchema* = object
    name*: string
    requestSchema*: string
    responseSchema*: string
    timeoutMs*: int
    retryPolicy*: string
    requiredCap*: string

  AirModule* = ref object
    sourcePath*: string
    strings*: seq[string]
    symbols*: seq[string]
    constants*: seq[Value]
    functions*: seq[AirFunction]
    effects*: seq[EffectProfile]
    toolSchemas*: seq[ToolSchema]
    diagnostics*: seq[string]
    mainFn*: int

proc newInst*(op: AirOpcode; mode: uint8 = 0; a: uint8 = 0; b: uint32 = 0; c: uint32 = 0; d: uint32 = 0): AirInst =
  AirInst(op: op, mode: mode, a: a, b: b, c: c, d: d)

proc newAirFunction*(name: string; arity = 0): AirFunction =
  AirFunction(
    id: -1,
    name: name,
    flags: {},
    arity: arity,
    params: @[],
    localCount: 0,
    localSymbols: @[],
    upvalueSymbols: @[],
    effectProfileId: -1,
    capabilityProfileId: -1,
    matcherRef: -1,
    code: @[]
  )

proc newAirModule*(sourcePath = "<memory>"): AirModule =
  AirModule(
    sourcePath: sourcePath,
    strings: @[],
    symbols: @[],
    constants: @[],
    functions: @[],
    effects: @[],
    toolSchemas: @[],
    diagnostics: @[],
    mainFn: -1
  )

proc internString*(m: AirModule; s: string): int =
  for i, existing in m.strings:
    if existing == s:
      return i
  let idx = m.strings.len
  m.strings.add(s)
  idx

proc internSymbol*(m: AirModule; s: string): int =
  for i, existing in m.symbols:
    if existing == s:
      return i
  let idx = m.symbols.len
  m.symbols.add(s)
  idx

proc addConstant*(m: AirModule; value: Value): int =
  let idx = m.constants.len
  m.constants.add(value)
  idx

proc addFunction*(m: AirModule; fn: AirFunction): int =
  let idx = m.functions.len
  fn.id = idx
  m.functions.add(fn)
  idx

proc emit*(fn: AirFunction; inst: AirInst): int =
  let idx = fn.code.len
  fn.code.add(inst)
  idx

proc patchB*(fn: AirFunction; ip: int; value: int) =
  fn.code[ip].b = value.uint32

proc patchC*(fn: AirFunction; ip: int; value: int) =
  fn.code[ip].c = value.uint32

proc patchD*(fn: AirFunction; ip: int; value: int) =
  fn.code[ip].d = value.uint32

proc ensureLocalSymbolCapacity*(fn: AirFunction; slot: int) =
  if slot >= fn.localSymbols.len:
    fn.localSymbols.setLen(slot + 1)

proc opName*(op: AirOpcode): string =
  $op

proc instToString*(inst: AirInst): string =
  fmt"{opName(inst.op):<18} mode={inst.mode:>3} a={inst.a:>3} b={inst.b:>5} c={inst.c:>5} d={inst.d:>5}"

proc functionToString*(m: AirModule; fn: AirFunction): string =
  var lines: seq[string] = @[]
  let flagText = fn.flags.toSeq().mapIt($it).join(",")
  lines.add(fmt"function {fn.id}: {fn.name}/{fn.arity} locals={fn.localCount} upvalues={fn.upvalueSymbols.len} flags=[{flagText}]")
  for i, param in fn.params:
    let t = if param.typeAnn.len == 0: "Any" else: param.typeAnn
    lines.add(fmt"  param {i}: {param.name}: {t}")
  for ip, inst in fn.code:
    lines.add(fmt"  {ip:>4}: {instToString(inst)}")
  lines.join("\n")

proc prettyPrint*(m: AirModule): string =
  var lines: seq[string] = @[]
  lines.add(fmt"AIR module source={m.sourcePath}")
  lines.add(fmt"symbols={m.symbols.len} constants={m.constants.len} functions={m.functions.len} mainFn={m.mainFn}")

  if m.symbols.len > 0:
    lines.add("symbol table:")
    for i, s in m.symbols:
      lines.add(fmt"  [{i}] {s}")

  if m.constants.len > 0:
    lines.add("constants:")
    for i, c in m.constants:
      lines.add(fmt"  [{i}] {c.toDebugString()}")

  for fn in m.functions:
    lines.add("")
    lines.add(functionToString(m, fn))

  if m.effects.len > 0:
    lines.add("")
    lines.add("effects:")
    for i, eff in m.effects:
      let capsText = eff.capabilities.join(",")
      lines.add(fmt"  [{i}] {eff.name} caps={capsText}")

  if m.toolSchemas.len > 0:
    lines.add("")
    lines.add("tool schemas:")
    for i, ts in m.toolSchemas:
      lines.add(fmt"  [{i}] {ts.name} cap={ts.requiredCap} timeoutMs={ts.timeoutMs}")

  if m.diagnostics.len > 0:
    lines.add("")
    lines.add("diagnostics:")
    for diag in m.diagnostics:
      lines.add("  - " & diag)

  lines.join("\n")
