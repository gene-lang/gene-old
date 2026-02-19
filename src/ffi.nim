import std/[strutils, math, random, tables, times]
import ./types
import ./vm

type
  NativeSignature* = object
    arity*: int
    isMacro*: bool
    capabilities*: seq[string]

  NimNativeFn* = NativeProc

proc registerNativeFn*(vm: var Vm; name: string; sig: NativeSignature; fn: NimNativeFn) =
  registerNative(vm, name, sig.arity, fn, sig.capabilities, sig.isMacro)

proc nativePrint(args: seq[Value]): Value =
  var pieces: seq[string] = @[]
  for a in args:
    pieces.add(a.toDebugString())
  stdout.write(pieces.join(" "))
  valueNil()

proc nativePrintln(args: seq[Value]): Value =
  var pieces: seq[string] = @[]
  for a in args:
    pieces.add(a.toDebugString())
  echo pieces.join(" ")
  valueNil()

proc nativeSqrt(args: seq[Value]): Value =
  if args.len == 0:
    return valueFloat(0)
  valueFloat(sqrt(asFloat(args[0])))

proc nativeStr(args: seq[Value]): Value =
  if args.len == 0:
    return newStringValue("")
  newStringValue(args[0].toDebugString())

proc nativeAppend(args: seq[Value]): Value =
  if args.len == 0:
    return newStringValue("")
  var textOut = args[0].asString()
  for i in 1..<args.len:
    textOut.add(args[i].asString())
  newStringValue(textOut)

proc nativeToI(args: seq[Value]): Value =
  if args.len == 0:
    return valueInt(0)
  let s = args[0].asString().strip()
  try:
    valueInt(parseInt(s))
  except ValueError:
    valueInt(0)

proc nativeToUpper(args: seq[Value]): Value =
  if args.len == 0:
    return newStringValue("")
  newStringValue(args[0].asString().toUpperAscii())

proc nativeLen(args: seq[Value]): Value =
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

proc nativeTypeof(args: seq[Value]): Value =
  if args.len == 0:
    return valueSymbol("nil")
  valueSymbol(inferTypeName(args[0]).toLowerAscii())

proc nativeNow(args: seq[Value]): Value =
  discard args
  valueInt(epochTime().int64)

proc nativeRand(args: seq[Value]): Value =
  var upper = 2147483647
  if args.len > 0:
    upper = asInt(args[0]).int
    if upper <= 0:
      upper = 1
  valueInt(rand(upper - 1))

proc nativeCallerEval(args: seq[Value]): Value =
  # Placeholder for pseudo macro caller evaluation support.
  if args.len == 0:
    return valueNil()
  args[0]

proc nativeResume(args: seq[Value]): Value =
  if args.len == 0:
    return valueNil()
  let g = asGeneratorObj(args[0])
  if g == nil:
    return valueNil()
  if g.state == GsDone:
    return g.lastValue
  valueNil()

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
