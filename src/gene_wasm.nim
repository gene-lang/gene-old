import std/[strutils]
import ./types
import ./parser
import ./compiler
import ./vm
import ./ffi

var gEvalOutput = ""
var gEvalResult = ""

proc appendPrinted(args: seq[Value]; newline: bool) =
  var pieces: seq[string] = @[]
  for a in args:
    pieces.add(a.toDebugString())
  gEvalOutput.add(pieces.join(" "))
  if newline:
    gEvalOutput.add("\n")

proc wasmPrint(vm: var Vm; args: seq[Value]): Value =
  discard vm
  appendPrinted(args, false)
  valueNil()

proc wasmPrintln(vm: var Vm; args: seq[Value]): Value =
  discard vm
  appendPrinted(args, true)
  valueNil()

proc registerPlaygroundNatives(vm: var Vm) =
  registerDefaultNatives(vm)
  registerNativeFn(vm, "print", NativeSignature(arity: -1, isMacro: false, capabilities: @[]), wasmPrint)
  registerNativeFn(vm, "println", NativeSignature(arity: -1, isMacro: false, capabilities: @[]), wasmPrintln)

proc evalGeneSource(source: string): string =
  gEvalOutput = ""
  try:
    let ast = parseProgram(source, "<playground>")
    let module = compileProgram(ast, "<playground>")
    var runtime = newVm()
    registerPlaygroundNatives(runtime)
    let value = runtime.runModule(module)
    if gEvalOutput.len > 0 and not gEvalOutput.endsWith("\n"):
      gEvalOutput.add("\n")
    if gEvalOutput.len == 0:
      value.toDebugString()
    else:
      gEvalOutput & value.toDebugString()
  except CatchableError as ex:
    if gEvalOutput.len > 0 and not gEvalOutput.endsWith("\n"):
      gEvalOutput.add("\n")
    gEvalOutput & "error: " & ex.msg

proc gene_eval*(code: cstring): cstring {.cdecl, exportc.} =
  let source = if code == nil: "" else: $code
  gEvalResult = evalGeneSource(source)
  gEvalResult.cstring

when defined(gene_wasm):
  import std/[times]

  var gHostRandState = 0x9E3779B97F4A7C15'u64

  proc hostRandNext(): int64 =
    gHostRandState = gHostRandState xor (gHostRandState shl 13)
    gHostRandState = gHostRandState xor (gHostRandState shr 7)
    gHostRandState = gHostRandState xor (gHostRandState shl 17)
    int64(gHostRandState and 0x7FFFFFFF'u64)

  proc gene_host_now*(): int64 {.cdecl, exportc.} =
    epochTime().int64

  proc gene_host_rand*(): int64 {.cdecl, exportc.} =
    hostRandNext()

  proc gene_host_file_exists*(path: cstring): cint {.cdecl, exportc.} =
    discard path
    0

  proc gene_host_read_file*(path: cstring; outBuf: ptr cstring; outLen: ptr cint): cint {.cdecl, exportc.} =
    discard path
    if outBuf != nil:
      outBuf[] = nil
    if outLen != nil:
      outLen[] = 0
    1

  proc gene_host_write_file*(path: cstring; data: cstring; len: cint): cint {.cdecl, exportc.} =
    discard path
    discard data
    discard len
    1

  proc gene_host_free*(p: pointer) {.cdecl, exportc.} =
    discard p
