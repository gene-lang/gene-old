import parseopt, times, strformat, terminal, os, strutils, streams, tables

import ../gene/types
import ../gene/vm
import ../gene/compiler
import ../gene/gir
import ../gene/repl_session
import ./base

const DEFAULT_COMMAND = "run"
const COMMANDS = @[DEFAULT_COMMAND]

type
  Options = ref object
    benchmark: bool
    debugging: bool
    print_result: bool
    repl_on_error: bool
    trace: bool
    trace_instruction: bool
    compile: bool
    profile: bool
    profile_instructions: bool
    no_gir_cache: bool  # Ignore GIR cache
    force_compile: bool  # Force recompilation even if cache is up-to-date
    type_check: bool
    file: string
    args: seq[string]

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("run <file>: parse and execute <file>")
  manager.add_help("  --repl-on-error: drop into REPL on Gene exceptions")
  manager.add_help("  --no-type-check: disable static type checking (alias: --no-typecheck)")

let short_no_val = {'d'}
let long_no_val = @[
  "repl-on-error",
  "trace",
  "trace-instruction",
  "compile",
  "profile",
  "profile-instructions",
  "no-gir-cache",
  "force-compile",
  "no-typecheck",
  "no-type-check",
]
proc parse_options(args: seq[string]): Options =
  result = Options(type_check: true)
  var found_file = false
  
  # Workaround: get_opt reads from command line when given empty args
  if args.len == 0:
    return
  
  for kind, key, value in get_opt(args, short_no_val, long_no_val):
    case kind
    of cmdArgument:
      if not found_file:
        found_file = true
        result.file = key
      else:
        result.args.add(key)
    of cmdLongOption, cmdShortOption:
      if found_file:
        result.args.add(key)
        if value != "":
          result.args.add(value)
      else:
        case key
        of "d", "debug":
          result.debugging = true
        of "repl-on-error":
          result.repl_on_error = true
        of "trace":
          result.trace = true
        of "trace-instruction":
          result.trace_instruction = true
        of "compile":
          result.compile = true
        of "profile":
          result.profile = true
        of "profile-instructions":
          result.profile_instructions = true
        of "no-gir-cache":
          result.no_gir_cache = true
        of "force-compile":
          result.force_compile = true
        of "no-typecheck", "no-type-check":
          result.type_check = false
        else:
          echo "Unknown option: ", key
          discard
    of cmdEnd:
      discard

proc handle*(cmd: string, args: seq[string]): CommandResult =
  let options = parse_options(args)
  setup_logger(options.debugging)
  proc handle_exec_error(e: ref CatchableError): CommandResult =
    if options.repl_on_error and VM.current_exception != NIL and VM.frame != nil:
      stderr.writeLine("Error: " & e.msg)
      let original_exception = VM.current_exception
      discard run_repl_on_error(VM, VM.current_exception)
      # Check if a new exception was thrown from the REPL
      if VM.current_exception != NIL and VM.current_exception != original_exception:
        # Format the exception message
        var msg = "Gene exception"
        if VM.current_exception.kind == VkString:
          msg = msg & ": " & VM.current_exception.str
        elif VM.current_exception.kind == VkInstance:
          # Try to extract message from exception instance
          let msg_key = "message".to_key()
          if msg_key in instance_props(VM.current_exception):
            let msg_val = instance_props(VM.current_exception)[msg_key]
            if msg_val.kind == VkString:
              msg = msg_val.str
            else:
              msg = $msg_val
          else:
            msg = $VM.current_exception
        else:
          msg = msg & ": " & $VM.current_exception
        return failure(msg)
      return failure("")
    return failure(e.msg)

  var file = options.file
  var code: string
  
  # Check if file is provided or read from stdin
  if file == "":
    # No file provided, try to read from stdin
    if not stdin.isatty():
      var lines: seq[string] = @[]
      var line: string
      while stdin.readLine(line):
        lines.add(line)
      if lines.len > 0:
        code = lines.join("\n")
        file = "<stdin>"
      else:
        return failure("No input provided. Provide a file to run.")
    else:
      return failure("No file provided to run.")
  else:
    # Check if file exists
    if not fileExists(file):
      return failure("File not found: " & file)

  init_app_and_vm()
  init_stdlib()
  set_program_args(file, options.args)
  VM.repl_on_error = options.repl_on_error

  if options.trace:
    VM.trace = true
  if options.profile:
    VM.profiling = true
  if options.profile_instructions:
    VM.instruction_profiling = true

  # Handle .gir files first (no caching logic)
  if file.endsWith(".gir"):
    let start = cpu_time()
    var compiled: CompilationUnit
    try:
      compiled = load_gir(file)
    except CatchableError as e:
      return failure("Loading GIR file: " & e.msg)

    if options.compile or options.debugging:
      echo "=== Loaded GIR: " & file & " ==="
      echo "Instructions: " & $compiled.instructions.len

    if VM.frame == nil:
      let ns = new_namespace(App.app.global_ns.ref.ns, file)
      ns["__module_name__".to_key()] = file.to_value()
      ns["__is_main__".to_key()] = TRUE
      ns["gene".to_key()] = App.app.gene_ns
      ns["genex".to_key()] = App.app.genex_ns
      VM.frame = new_frame(ns)
      let args_gene = new_gene(NIL)
      args_gene.children.add(ns.to_value())
      VM.frame.args = args_gene.to_gene_value()
    VM.cu = compiled
    try:
      discard VM.exec()
      discard VM.maybe_run_module_init()
    except CatchableError as e:
      return handle_exec_error(e)

    let elapsed = cpu_time() - start
    if options.profile:
      VM.print_profile()
    if options.profile_instructions:
      VM.print_instruction_profile()
    if options.benchmark:
      echo fmt"Execution time: {elapsed * 1000:.3f} ms"
    return success()

  # Regular .gene file - check for cached GIR
  if not options.no_gir_cache and not options.force_compile:
    let gir_path = get_gir_path(file, "build")
    if fileExists(gir_path) and is_gir_up_to_date(gir_path, file):
      if options.debugging:
        echo "Using cached GIR: " & gir_path

      let start = cpu_time()
      var compiled: CompilationUnit
      try:
        compiled = load_gir(gir_path)
      except CatchableError:
        compiled = nil

        if not compiled.isNil:
          if VM.frame == nil:
            let ns = new_namespace(App.app.global_ns.ref.ns, file)
            ns["__module_name__".to_key()] = file.to_value()
            ns["__is_main__".to_key()] = TRUE
            ns["gene".to_key()] = App.app.gene_ns
            ns["genex".to_key()] = App.app.genex_ns
            VM.frame = new_frame(ns)
            let args_gene = new_gene(NIL)
            args_gene.children.add(ns.to_value())
            VM.frame.args = args_gene.to_gene_value()
        VM.cu = compiled
        try:
          discard VM.exec()
          discard VM.maybe_run_module_init()
        except CatchableError as e:
          return handle_exec_error(e)

        let elapsed = cpu_time() - start
        if options.profile:
          VM.print_profile()
        if options.profile_instructions:
          VM.print_instruction_profile()
        if options.benchmark:
          echo fmt"Execution time: {elapsed * 1000:.3f} ms (from cache)"
        return success()

  let start = cpu_time()
  var value: Value
  try:
    if options.trace_instruction:
      # For trace/debug modes, we need to read the file into memory
      # so we can inspect compilation output and then execute
      let code = if code != "": code else: readFile(file)
      echo "=== Compilation Output ==="
      let compiled = parse_and_compile(code, file, type_check = options.type_check, module_mode = true, run_init = false)
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:04X} {instr}"
      echo ""
      echo "=== Execution Trace ==="
      VM.trace = true
      # Initialize frame if needed
      if VM.frame == nil:
        let ns = new_namespace(App.app.global_ns.ref.ns, file)
        ns["__module_name__".to_key()] = file.to_value()
        ns["__is_main__".to_key()] = TRUE
        ns["gene".to_key()] = App.app.gene_ns
        ns["genex".to_key()] = App.app.genex_ns
        App.app.gene_ns.ref.ns["main_module".to_key()] = file.to_value()
        VM.frame = new_frame(ns)
        let args_gene = new_gene(NIL)
        args_gene.children.add(ns.to_value())
        VM.frame.args = args_gene.to_gene_value()
      else:
        let ns = new_namespace(App.app.global_ns.ref.ns, file)
        ns["__module_name__".to_key()] = file.to_value()
        ns["__is_main__".to_key()] = TRUE
        ns["gene".to_key()] = App.app.gene_ns
        ns["genex".to_key()] = App.app.genex_ns
        App.app.gene_ns.ref.ns["main_module".to_key()] = file.to_value()
        VM.frame.update(new_frame(ns))
        let args_gene = new_gene(NIL)
        args_gene.children.add(ns.to_value())
        VM.frame.args = args_gene.to_gene_value()
      VM.cu = compiled
      value = VM.exec()
      let init_result = VM.maybe_run_module_init()
      if init_result.ran:
        value = init_result.value
    elif options.compile or options.debugging:
      # For trace/debug modes, we need to read the file into memory
      let code = if code != "": code else: readFile(file)
      echo "=== Compilation Output ==="
      let compiled = parse_and_compile(code, file, type_check = options.type_check, module_mode = true, run_init = false)
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:03d}: {instr}"
      echo ""

      if not options.trace:  # If not tracing, just show compilation
        VM.cu = compiled
        value = VM.exec()
      else:
        echo "=== Execution Trace ==="
        VM.cu = compiled
      value = VM.exec()
      let init_result = VM.maybe_run_module_init()
      if init_result.ran:
        value = init_result.value
    else:
      # Normal execution
      # Check if code was already read (from stdin or --eval)
      if code != "":
        # Code already in memory - use string-based execution
        value = VM.exec(code, file)
      else:
        # Read from file using streaming for memory efficiency
        let stream = newFileStream(file, fmRead)
        if stream.isNil:
          stderr.writeLine("Error: Failed to open file: " & file)
          return failure("Failed to open file")
        defer: stream.close()
        value = VM.exec(stream, file)
  except CatchableError as e:
    return handle_exec_error(e)
  
  if options.print_result:
    echo value
  if options.benchmark:
    echo "Time: " & $(cpu_time() - start)
  if options.profile:
    VM.print_profile()
  if options.profile_instructions:
    VM.print_instruction_profile()
  
  return success()

when isMainModule:
  let cmd = DEFAULT_COMMAND
  let args: seq[string] = @[]
  let result = handle(cmd, args)
  if not result.success:
    echo "Failed with error: " & result.error
