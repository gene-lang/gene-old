import std/[unittest, os, strutils]
import ../src/types
import ../src/parser
import ../src/compiler
import ../src/ir
import ../src/air_codec
import ../src/air_verify
import ../src/vm
import ../src/ffi

suite "AIR Codec":
  test "encode/decode roundtrip preserves executable behavior":
    let prog = parseProgram("(var x 2)\n(+ x 40)")
    let m = compileProgram(prog, "<roundtrip>")
    let blob = encodeAirModule(m)
    check blob.len > 0

    let decoded = decodeAirModule(blob)
    check decoded.functions.len == m.functions.len
    check decoded.mainFn == m.mainFn
    check verifyAirModule(decoded).len == 0

    var vm1 = newVm()
    registerDefaultNatives(vm1)
    let r1 = vm1.runModule(m)

    var vm2 = newVm()
    registerDefaultNatives(vm2)
    let r2 = vm2.runModule(decoded)

    check isInt(r1)
    check isInt(r2)
    check asInt(r1) == 42
    check asInt(r2) == 42

  test "write/read .gair file":
    let prog = parseProgram("(+ 1 2)")
    let m = compileProgram(prog, "<file>")
    let tmp = getTempDir() / "gene_air_codec_test.gair"
    defer:
      if fileExists(tmp):
        removeFile(tmp)

    writeAirModule(m, tmp)
    check fileExists(tmp)
    let loaded = readAirModule(tmp)
    check loaded.functions.len == m.functions.len
    check verifyAirModule(loaded).len == 0

suite "AIR Verifier":
  test "detects invalid jump target":
    let prog = parseProgram("42")
    let m = compileProgram(prog)
    m.functions[m.mainFn].code.insert(newInst(OpJump, b = 999'u32), 0)
    let issues = verifyAirModule(m)
    check issues.len > 0
    check issues[0].contains("AIR.VERIFY.JUMP_TARGET")

  test "detects stack underflow":
    let m = newAirModule("<underflow>")
    let fn = newAirFunction("__main__", 0)
    fn.code.add(newInst(OpPop))
    fn.code.add(newInst(OpReturn))
    discard m.addFunction(fn)
    m.mainFn = 0
    let issues = verifyAirModule(m)
    check issues.len > 0
    var found = false
    for issue in issues:
      if issue.contains("AIR.VERIFY.STACK_UNDERFLOW"):
        found = true
    check found == true
