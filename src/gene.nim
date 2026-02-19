import os, strutils
import types, parser, ir, compiler, vm, ffi

proc printUsage() =
  echo "Gene CLI"
  echo "Usage: gene <run|eval|repl|compile> [args]"

proc cmdRun(path: string): int =
  let source = readFile(path)
  let ast = parseProgram(source, path)
  let module = compileProgram(ast, path)
  var runtime = newVm()
  registerDefaultNatives(runtime)
  discard runtime.runModule(module)
  return 0

proc cmdEval(code: string): int =
  let ast = parseProgram(code, "<eval>")
  let module = compileProgram(ast, "<eval>")
  var runtime = newVm()
  registerDefaultNatives(runtime)
  let outValue = runtime.runModule(module)
  echo outValue.toDebugString()
  return 0

proc cmdRepl(): int =
  var runtime = newVm()
  registerDefaultNatives(runtime)
  echo "Gene REPL (type :quit to exit)"
  while true:
    stdout.write("> ")
    stdout.flushFile()
    if stdin.endOfFile:
      break
    let line = stdin.readLine()
    if line.strip() == ":quit":
      break
    if line.strip().len == 0:
      continue
    try:
      let ast = parseProgram(line, "<repl>")
      let module = compileProgram(ast, "<repl>")
      let value = runtime.runModule(module)
      echo value.toDebugString()
    except CatchableError as ex:
      echo "error: ", ex.msg
  return 0

proc cmdCompile(inputPath: string; outputPath: string): int =
  let source = readFile(inputPath)
  let ast = parseProgram(source, inputPath)
  let module = compileProgram(ast, inputPath)
  writeFile(outputPath, module.prettyPrint())
  return 0

proc main*(): int =
  let args = commandLineParams()
  if args.len == 0:
    printUsage()
    return 1

  case args[0]
  of "run":
    if args.len < 2:
      echo "run requires a path"
      return 1
    return cmdRun(args[1])
  of "eval":
    if args.len < 2:
      echo "eval requires code"
      return 1
    return cmdEval(args[1..^1].join(" "))
  of "repl":
    return cmdRepl()
  of "compile":
    if args.len < 3:
      echo "compile requires input and output paths"
      return 1
    return cmdCompile(args[1], args[2])
  else:
    printUsage()
    return 1

when isMainModule:
  quit(main())
