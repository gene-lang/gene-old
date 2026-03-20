import parseopt, times, strformat, terminal, os, strutils, streams, tables

import ../gene/types
import ../gene/vm
import ../gene/compiler
import ../gene/gir
import ../gene/repl_session
import ../gene/error_display
import ./base
import ./package_context

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
    contracts_enabled: bool
    native_tier: NativeCompileTier
    native_code: bool
    pkg: string
    file: string
    args: seq[string]

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("run <file>: parse and execute <file>")
  manager.add_help("  --pkg <package>: resolve relative entry files from a package root or package name")
  manager.add_help("  --repl-on-error: drop into REPL on Gene exceptions")
  manager.add_help("  --no-type-check: disable static type checking (alias: --no-typecheck)")
  manager.add_help("  --contracts <on|off>: enable or disable runtime contract checks")
  manager.add_help("  --native-code: enable native code execution (alias for --native-tier guarded)")
  manager.add_help("  --native-tier <never|guarded|fully-typed>: set native compilation policy")

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
  "native-code",
]

proc parse_native_tier(value: string): NativeCompileTier =
  case value.toLowerAscii()
  of "never":
    NctNever
  of "guarded":
    NctGuarded
  of "fully-typed", "fully_typed", "fullytyped":
    NctFullyTyped
  else:
    raise newException(ValueError, "Unknown native tier: " & value)

proc parse_contracts_enabled(value: string): bool =
  case value.toLowerAscii()
  of "on", "true", "1":
    true
  of "off", "false", "0":
    false
  else:
    raise newException(ValueError, "Unknown contracts mode: " & value)

proc parse_options(args: seq[string]): Options =
  result = Options(type_check: true, contracts_enabled: true, native_tier: NctNever)
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
        of "native-code":
          result.native_code = true
          if result.native_tier == NctNever:
            result.native_tier = NctGuarded
        of "native-tier":
          try:
            result.native_tier = parse_native_tier(value)
            result.native_code = result.native_tier != NctNever
          except ValueError as e:
            echo e.msg
        of "contracts":
          try:
            result.contracts_enabled = parse_contracts_enabled(value)
          except ValueError as e:
            echo e.msg
        of "pkg":
          result.pkg = value
        else:
          echo "Unknown option: ", key
          discard
    of cmdEnd:
      discard

proc prepare_main_module_frame(module_name: string, pkg_ctx: CliPackageContext) =
  let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
  configure_main_namespace(ns, module_name, pkg_ctx)

  let frame = new_frame(ns)
  let args_gene = new_gene(NIL)
  args_gene.children.add(ns.to_value())
  frame.args = args_gene.to_gene_value()

  if VM.frame == nil:
    VM.frame = frame
  else:
    VM.frame.update(frame)

proc execute_compiled_module(compiled: CompilationUnit, module_name: string, pkg_ctx: CliPackageContext): Value =
  prepare_main_module_frame(module_name, pkg_ctx)
  VM.cu = compiled
  result = VM.exec()
  let init_result = VM.maybe_run_module_init()
  if init_result.ran:
    result = init_result.value

proc handle*(cmd: string, args: seq[string]): CommandResult =
  let options = parse_options(args)
  setup_logger(options.debugging)
  proc handle_exec_error(e: ref CatchableError): CommandResult =
    if options.repl_on_error and VM.current_exception != NIL and VM.frame != nil:
      stderr.writeLine("Error: " & render_error_message(e.msg))
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
        return failure(render_error_message(msg))
      return failure("")
    return failure(render_error_message(e.msg))

  var file = options.file
  var module_name = file
  var code: string
  var pkg_ctx = disabled_cli_package_context()

  if options.pkg.len > 0:
    try:
      pkg_ctx = resolve_cli_package_context(options.pkg, getCurrentDir(), "<run>")
    except CatchableError as e:
      return failure(e.msg)
  
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
        module_name = virtual_module_name(pkg_ctx, "run_stdin", file)
      else:
        return failure("No input provided. Provide a file to run.")
    else:
      return failure("No file provided to run.")
  else:
    file = resolve_package_path(pkg_ctx, file)
    module_name = file
    # Check if file exists
    if not fileExists(file):
      return failure("File not found: " & file)

  if not pkg_ctx.enabled:
    let discovery_path =
      if file.len > 0 and file != "<stdin>":
        file
      else:
        getCurrentDir()
    try:
      pkg_ctx = resolve_cli_package_context("", getCurrentDir(), "<run>", discovery_path)
    except CatchableError as e:
      return failure(e.msg)
    if file == "<stdin>":
      module_name = virtual_module_name(pkg_ctx, "run_stdin", file)

  init_app_and_vm()
  VM.native_tier = options.native_tier
  VM.native_code = options.native_tier != NctNever
  VM.type_check = options.type_check
  VM.contracts_enabled = options.contracts_enabled
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

    try:
      discard execute_compiled_module(compiled, module_name, pkg_ctx)
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
  if file != "<stdin>" and not options.no_gir_cache and not options.force_compile:
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
        if options.debugging:
          echo "Cached GIR load failed (" & gir_path & "), recompiling source."

      if not compiled.isNil:
        try:
          discard execute_compiled_module(compiled, module_name, pkg_ctx)
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
      let compiled = parse_and_compile(code, module_name, type_check = options.type_check, module_mode = true, run_init = false)
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:04X} {instr}"
      echo ""
      echo "=== Execution Trace ==="
      VM.trace = true
      value = execute_compiled_module(compiled, module_name, pkg_ctx)
    elif options.compile or options.debugging:
      # For trace/debug modes, we need to read the file into memory
      let code = if code != "": code else: readFile(file)
      echo "=== Compilation Output ==="
      let compiled = parse_and_compile(code, module_name, type_check = options.type_check, module_mode = true, run_init = false)
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:03d}: {instr}"
      echo ""

      if options.trace:
        echo "=== Execution Trace ==="
      value = execute_compiled_module(compiled, module_name, pkg_ctx)
    else:
      # Normal execution
      # Compile and execute with module mode so run follows parse+compile+execute.
      if code != "":
        let compiled = parse_and_compile(code, module_name, type_check = options.type_check, module_mode = true, run_init = false)
        value = execute_compiled_module(compiled, module_name, pkg_ctx)
      else:
        let stream = newFileStream(file, fmRead)
        if stream.isNil:
          stderr.writeLine("Error: Failed to open file: " & file)
          return failure("Failed to open file")
        defer: stream.close()
        let compiled = parse_and_compile(stream, module_name, type_check = options.type_check, module_mode = true, run_init = false)
        value = execute_compiled_module(compiled, module_name, pkg_ctx)
        if not options.no_gir_cache:
          let gir_path = get_gir_path(file, "build")
          try:
            save_gir(compiled, gir_path, file)
          except CatchableError as save_err:
            if options.debugging:
              echo "Skipping GIR cache write (" & gir_path & "): " & save_err.msg
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
