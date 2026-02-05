## Native code runtime utilities (JIT allocation + codegen dispatch)
import ../types
import ./hir
import ./bytecode_to_hir

when defined(amd64):
  import ./x86_64_codegen as codegen
  const nativeArch* = "x86_64"
elif defined(arm64) or defined(aarch64):
  import ./arm64_codegen as codegen
  const nativeArch* = "arm64"
else:
  const nativeArch* = "none"

type
  NativeCompileResult* = object
    ok*: bool
    entry*: pointer
    code*: seq[byte]
    message*: string
    returnFloat*: bool  # True if native function returns float64 (bitcast as int64)

when defined(posix):
  import std/posix
  proc clear_cache(start, `end`: ptr char) {.importc: "__builtin___clear_cache".}
  when defined(macosx):
    proc pthread_jit_write_protect_np(enable: cint) {.importc.}

proc validate_hir(fn: HirFunction): bool =
  for blk in fn.blocks:
    for op in blk.ops:
      case op.kind
      of HokConstI64, HokAddI64, HokSubI64, HokMulI64, HokDivI64, HokNegI64,
         HokLeI64, HokLtI64, HokGeI64, HokGtI64, HokEqI64, HokNeI64,
         HokConstF64, HokAddF64, HokSubF64, HokMulF64, HokDivF64, HokNegF64,
         HokLeF64, HokLtF64, HokGeF64, HokGtF64, HokEqF64, HokNeF64,
         HokBr, HokJump, HokRet, HokCall:
        if op.kind == HokCall and op.callTarget != fn.name:
          return false
      else:
        return false
  true

proc make_executable(code: seq[byte]): pointer =
  when not defined(posix):
    return nil

  if code.len == 0:
    return nil

  let size = code.len
  let prot = PROT_READ or PROT_WRITE or PROT_EXEC
  const MAP_ANON_FLAG = when defined(macosx): 0x1000.cint else: 0x20.cint
  const MAP_JIT_FLAG = when defined(macosx): 0x800.cint else: 0.cint
  let flags = MAP_PRIVATE or MAP_ANON_FLAG or MAP_JIT_FLAG

  let mem = mmap(nil, size.cint, prot, flags, -1.cint, 0.Off)
  if mem == MAP_FAILED:
    return nil

  when defined(macosx):
    pthread_jit_write_protect_np(0)

  copyMem(mem, code[0].unsafeAddr, size)

  when defined(macosx):
    pthread_jit_write_protect_np(1)

  clear_cache(cast[ptr char](mem), cast[ptr char](cast[uint64](mem) + uint64(size)))
  return mem

proc compile_to_native*(cu: CompilationUnit, fn_name: string): NativeCompileResult =
  result.ok = false

  when nativeArch == "none":
    result.message = "Native codegen not supported on this architecture"
    return

  if not isNativeEligible(cu, fn_name):
    result.message = "Function not eligible for native compilation"
    return

  try:
    let hir = bytecodeToHir(cu, fn_name)
    if not validate_hir(hir):
      result.message = "HIR contains unsupported operations"
      return
    let code = codegen.generateCode(hir)
    let entry = make_executable(code)
    if entry.is_nil:
      result.message = "Failed to allocate executable memory"
      return
    result.ok = true
    result.entry = entry
    result.code = code
    result.returnFloat = hir.returnType == HtF64
  except CatchableError as e:
    result.message = "Native codegen failed: " & e.msg
