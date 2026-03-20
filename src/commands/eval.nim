import parseopt, strutils, strformat, tables, os
import ../gene/types
import ../gene/vm
import ../gene/compiler
import ../gene/repl_session
import ../gene/error_display
import ./base
import ./package_context

const DEFAULT_COMMAND = "eval"
const COMMANDS = @[DEFAULT_COMMAND, "e"]

type
  Options = ref object
    debugging: bool
    print_result: bool
    print_last: bool
    csv: bool
    gene: bool
    line: bool
    trace: bool
    trace_instruction: bool
    compile: bool
    repl_on_error: bool
    type_check: bool
    contracts_enabled: bool
    native_tier: NativeCompileTier
    native_code: bool
    pkg: string
    code: string

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("eval <code>: evaluate <code> as a gene expression")
  manager.add_help("  -d, --debug: enable debug output")
  manager.add_help("  --pkg <package>: execute the eval session in a package context")
  manager.add_help("  --repl-on-error: drop into REPL on Gene exceptions")
  manager.add_help("  --no-type-check: disable static type checking (alias: --no-typecheck)")
  manager.add_help("  --contracts <on|off>: enable or disable runtime contract checks")
  manager.add_help("  --native-code: enable native code execution (alias for --native-tier guarded)")
  manager.add_help("  --native-tier <never|guarded|fully-typed>: set native compilation policy")
  manager.add_help("  --csv: print result as CSV")
  manager.add_help("  --gene: print result as gene expression")
  manager.add_help("  --line: evaluate as a single line")
  manager.add_help("  -p --print-last: print the result of the last expression")

let short_no_val = {'d', 'p'}
let long_no_val = @[
  "csv",
  "gene",
  "line",
  "repl-on-error",
  "trace",
  "trace-instruction",
  "compile",
  "no-typecheck",
  "no-type-check",
  "native-code",
  "print-last",
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
  var code_parts: seq[string] = @[]
  
  # Workaround: get_opt reads from command line when given empty args
  if args.len == 0:
    return
  
  for kind, key, value in get_opt(args, short_no_val, long_no_val):
    case kind
    of cmdArgument:
      code_parts.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "d", "debug":
        result.debugging = true
      of "csv":
        result.csv = true
      of "gene":
        result.gene = true
      of "line":
        result.line = true
      of "repl-on-error":
        result.repl_on_error = true
      of "trace":
        result.trace = true
      of "trace-instruction":
        result.trace_instruction = true
      of "compile":
        result.compile = true
      of "no-typecheck", "no-type-check":
        result.type_check = false
      of "p", "print-last":
        result.print_last = true
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
    of cmdEnd:
      discard
  
  result.code = code_parts.join(" ")

proc prepare_eval_frame(module_name: string, pkg_ctx: CliPackageContext) =
  let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
  configure_main_namespace(ns, module_name, pkg_ctx)
  if VM.frame == nil:
    VM.frame = new_frame(ns)
  else:
    VM.frame.update(new_frame(ns))

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
  
  var code = options.code
  
  # If no code provided via arguments, read from stdin
  if code.len == 0:
    # Try to read from stdin regardless of TTY status
    var lines: seq[string] = @[]
    var line: string
    while read_line(stdin, line):
      lines.add(line)
    if lines.len > 0:
      code = lines.join("\n")
    else:
      return failure("No code provided to evaluate")
  
  if code.len == 0:
    return failure("No code provided to evaluate")

  var pkg_ctx = disabled_cli_package_context()
  try:
    pkg_ctx = resolve_cli_package_context(options.pkg, getCurrentDir(), "<eval>")
  except CatchableError as e:
    return failure(e.msg)
  let module_name = virtual_module_name(pkg_ctx, "eval", "<eval>")
  
  init_app_and_vm()
  VM.native_tier = options.native_tier
  VM.native_code = options.native_tier != NctNever
  VM.type_check = options.type_check
  VM.contracts_enabled = options.contracts_enabled
  init_stdlib()
  set_program_args("<eval>", @[])
  VM.repl_on_error = options.repl_on_error
  
  
  try:
    # Enable tracing if requested
    if options.trace:
      VM.trace = true
    
    # Handle trace-instruction option
    if options.trace_instruction:
      # Show both compilation and execution with trace
      let compiled = parse_and_compile(code, module_name, type_check = options.type_check, module_mode = true, run_init = false)
      echo "=== Compilation Output ==="
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:04X} {instr}"
      echo ""
      echo "=== Execution Trace ==="
      VM.trace = true
      prepare_eval_frame(module_name, pkg_ctx)
      VM.cu = compiled
      let value = VM.exec()
      echo "=== Final Result ==="
      echo $value
    # Show compilation details if requested
    elif options.compile or options.debugging:
      let compiled = parse_and_compile(code, module_name, type_check = options.type_check, module_mode = true, run_init = false)
      echo "=== Compilation Output ==="
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:03d}: {instr}"
      echo ""
      
      if not options.trace:  # If not tracing, just show compilation
        prepare_eval_frame(module_name, pkg_ctx)
        VM.cu = compiled
        let value = VM.exec()
        echo "=== Result ==="
        echo $value
      else:
        echo "=== Execution Trace ==="
        prepare_eval_frame(module_name, pkg_ctx)
        VM.cu = compiled
        let value = VM.exec()
        echo "=== Final Result ==="
        echo $value
    else:
      let value = VM.exec(code, module_name, pkg_ctx.name, pkg_ctx.root)
      if options.print_last:
        echo $value
        
  except CatchableError as e:
    return handle_exec_error(e)
  
  return success()

when isMainModule:
  let cmd = DEFAULT_COMMAND
  let args: seq[string] = @[]
  let result = handle(cmd, args)
  if not result.success:
    echo "Failed with error: " & result.error
