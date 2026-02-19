import std/[strutils, math, random, tables, times]
import ./types
import ./vm
import ./ir

type
  NativeSignature* = object
    arity*: int
    isMacro*: bool
    capabilities*: seq[string]

  NimNativeFn* = NativeProc

proc registerNativeFn*(vm: var Vm; name: string; sig: NativeSignature; fn: NimNativeFn) =
  registerNative(vm, name, sig.arity, fn, sig.capabilities, sig.isMacro)

proc nativePrint(vm: var Vm; args: seq[Value]): Value =
  discard vm
  var pieces: seq[string] = @[]
  for a in args:
    pieces.add(a.toDebugString())
  stdout.write(pieces.join(" "))
  valueNil()

proc nativePrintln(vm: var Vm; args: seq[Value]): Value =
  discard vm
  var pieces: seq[string] = @[]
  for a in args:
    pieces.add(a.toDebugString())
  echo pieces.join(" ")
  valueNil()

proc nativeSqrt(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return valueFloat(0)
  valueFloat(sqrt(asFloat(args[0])))

proc nativeStr(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return newStringValue("")
  newStringValue(args[0].toDebugString())

proc nativeAppend(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return newStringValue("")
  var textOut = args[0].asString()
  for i in 1..<args.len:
    textOut.add(args[i].asString())
  newStringValue(textOut)

proc nativeToI(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return valueInt(0)
  let s = args[0].asString().strip()
  try:
    valueInt(parseInt(s))
  except ValueError:
    valueInt(0)

proc nativeToUpper(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return newStringValue("")
  newStringValue(args[0].asString().toUpperAscii())

proc nativeLen(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return valueInt(0)

  let arr = asArrayObj(args[0])
  if arr != nil:
    return valueInt(arr.items.len)

  let m = asMapObj(args[0])
  if m != nil:
    return valueInt(len(m.entries))

  let s = asStringObj(args[0])
  if s != nil:
    return valueInt(s.value.len)

  valueInt(0)

proc nativeTypeof(vm: var Vm; args: seq[Value]): Value =
  discard vm
  if args.len == 0:
    return valueSymbol("nil")
  valueSymbol(inferTypeName(args[0]).toLowerAscii())

proc nativeNow(vm: var Vm; args: seq[Value]): Value =
  discard vm
  discard args
  valueInt(epochTime().int64)

proc nativeRand(vm: var Vm; args: seq[Value]): Value =
  discard vm
  var upper = 2147483647
  if args.len > 0:
    upper = asInt(args[0]).int
    if upper <= 0:
      upper = 1
  valueInt(rand(upper - 1))

proc nativeCallerEval(vm: var Vm; args: seq[Value]): Value =
  discard vm
  # Placeholder for pseudo macro caller evaluation support.
  if args.len == 0:
    return valueNil()
  args[0]

proc nativeResume(vm: var Vm; args: seq[Value]): Value =
  if args.len == 0:
    return valueNil()
  resumeValue(vm, args[0])

proc nativeCapGrant(vm: var Vm; args: seq[Value]): Value =
  if args.len == 0:
    return valueNil()
  grantCapability(vm, args[0].asString())
  valueBool(true)

proc nativeCapRevoke(vm: var Vm; args: seq[Value]): Value =
  if args.len == 0:
    return valueNil()
  revokeCapability(vm, args[0].asString())
  valueBool(true)

proc nativeCapClear(vm: var Vm; args: seq[Value]): Value =
  discard args
  clearCapabilities(vm)
  valueBool(true)

proc nativeQuotaLimit(vm: var Vm; args: seq[Value]): Value =
  if args.len < 2:
    return valueBool(false)
  let kind = args[0].asString().toLowerAscii()
  var limit: int64
  if isInt(args[1]):
    limit = asInt(args[1])
  else:
    try:
      limit = parseInt(args[1].asString()).int64
    except ValueError:
      return valueBool(false)
  case kind
  of "cpu", "steps":
    setQuotaLimit(vm, QkCpuSteps, limit)
  of "heap", "memory":
    setQuotaLimit(vm, QkHeapObjects, limit)
  of "time", "wall":
    setQuotaLimit(vm, QkWallClockMs, limit)
  of "tool", "toolcalls":
    setQuotaLimit(vm, QkToolCalls, limit)
  else:
    return valueBool(false)
  valueBool(true)

proc nativeCheckpointSave(vm: var Vm; args: seq[Value]): Value =
  if args.len == 0:
    return valueBool(false)
  saveVmCheckpoint(vm, args[0].asString())
  valueBool(true)

proc nativeCheckpointLoad(vm: var Vm; args: seq[Value]): Value =
  if args.len == 0:
    return valueBool(false)
  valueBool(loadVmCheckpoint(vm, args[0].asString()))

proc toolEchoHandler(vm: var Vm; req: ToolCallRequest): ToolCallResult =
  discard vm
  ToolCallResult(ok: true, value: req.args, error: valueNil())

proc toolNowHandler(vm: var Vm; req: ToolCallRequest): ToolCallResult =
  discard vm
  discard req
  let m = newMapValue()
  mapSet(m, newKeywordValue("unix"), valueInt(epochTime().int64))
  ToolCallResult(
    ok: true,
    value: m,
    error: valueNil()
  )

proc registerDefaultNatives*(vm: var Vm) =
  randomize()

  registerNativeFn(vm, "print", NativeSignature(arity: -1, isMacro: false, capabilities: @[]), nativePrint)
  registerNativeFn(vm, "println", NativeSignature(arity: -1, isMacro: false, capabilities: @[]), nativePrintln)
  registerNativeFn(vm, "sqrt", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeSqrt)
  registerNativeFn(vm, "str", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeStr)
  registerNativeFn(vm, "append", NativeSignature(arity: -1, isMacro: false, capabilities: @[]), nativeAppend)
  registerNativeFn(vm, "to_i", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeToI)
  registerNativeFn(vm, "to_upper", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeToUpper)
  registerNativeFn(vm, "len", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeLen)
  registerNativeFn(vm, "typeof", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeTypeof)
  registerNativeFn(vm, "now", NativeSignature(arity: 0, isMacro: false, capabilities: @["cap.clock.real"]), nativeNow)
  registerNativeFn(vm, "rand", NativeSignature(arity: -1, isMacro: false, capabilities: @["cap.rand.nondet"]), nativeRand)
  registerNativeFn(vm, "$caller_eval", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeCallerEval)
  registerNativeFn(vm, "resume", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeResume)
  registerNativeFn(vm, "cap_grant", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeCapGrant)
  registerNativeFn(vm, "cap_revoke", NativeSignature(arity: 1, isMacro: false, capabilities: @[]), nativeCapRevoke)
  registerNativeFn(vm, "cap_clear", NativeSignature(arity: 0, isMacro: false, capabilities: @[]), nativeCapClear)
  registerNativeFn(vm, "quota_limit", NativeSignature(arity: 2, isMacro: false, capabilities: @[]), nativeQuotaLimit)
  registerNativeFn(vm, "checkpoint_save", NativeSignature(arity: 1, isMacro: false, capabilities: @["cap.state.checkpoint"]), nativeCheckpointSave)
  registerNativeFn(vm, "checkpoint_load", NativeSignature(arity: 1, isMacro: false, capabilities: @["cap.state.checkpoint"]), nativeCheckpointLoad)

  registerTool(vm, ToolSchema(
    name: "tool/echo",
    requestSchema: "required:msg",
    responseSchema: "",
    timeoutMs: 15000,
    retryPolicy: "retries:0",
    requiredCap: "cap.tool.call:tool/echo"
  ), toolEchoHandler)

  registerTool(vm, ToolSchema(
    name: "tool/now",
    requestSchema: "",
    responseSchema: "",
    timeoutMs: 15000,
    retryPolicy: "retries:0",
    requiredCap: "cap.tool.call:tool/now"
  ), toolNowHandler)
