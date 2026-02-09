import parseopt, strutils, strformat, tables
import ../gene/types
import ../gene/vm
import ../gene/compiler
import ../gene/repl_session
import ./base

const DEFAULT_COMMAND = "eval"
const COMMANDS = @[DEFAULT_COMMAND, "e"]

type
  Options = ref object
    debugging: bool
    print_result: bool
    csv: bool
    gene: bool
    line: bool
    trace: bool
    trace_instruction: bool
    compile: bool
    repl_on_error: bool
    type_check: bool
    native_code: bool
    code: string

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("eval <code>: evaluate <code> as a gene expression")
  manager.add_help("  -d, --debug: enable debug output")
  manager.add_help("  --repl-on-error: drop into REPL on Gene exceptions")
  manager.add_help("  --no-type-check: disable static type checking (alias: --no-typecheck)")
  manager.add_help("  --native-code: enable native code execution when available")
  manager.add_help("  --csv: print result as CSV")
  manager.add_help("  --gene: print result as gene expression")
  manager.add_help("  --line: evaluate as a single line")

let short_no_val = {'d'}
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
]

proc parse_options(args: seq[string]): Options =
  result = Options(type_check: true)
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
      of "native-code":
        result.native_code = true
      else:
        echo "Unknown option: ", key
    of cmdEnd:
      discard
  
  result.code = code_parts.join(" ")

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
  
  init_app_and_vm()
  VM.native_code = options.native_code
  VM.type_check = options.type_check
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
      let compiled = parse_and_compile(code, type_check = options.type_check)
      echo "=== Compilation Output ==="
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:04X} {instr}"
      echo ""
      echo "=== Execution Trace ==="
      VM.trace = true
      # Initialize frame if needed
      if VM.frame == nil:
        let ns = new_namespace(App.app.global_ns.ref.ns, "<eval>")
        ns["__module_name__".to_key()] = "<eval>".to_value()
        ns["__is_main__".to_key()] = TRUE
        ns["gene".to_key()] = App.app.gene_ns
        ns["genex".to_key()] = App.app.genex_ns
        VM.frame = new_frame(ns)
      VM.cu = compiled
      let value = VM.exec()
      echo "=== Final Result ==="
      echo $value
    # Show compilation details if requested
    elif options.compile or options.debugging:
      let compiled = parse_and_compile(code, type_check = options.type_check)
      echo "=== Compilation Output ==="
      echo "Instructions:"
      for i, instr in compiled.instructions:
        echo fmt"{i:03d}: {instr}"
      echo ""
      
      if not options.trace:  # If not tracing, just show compilation
        VM.cu = compiled
        let value = VM.exec()
        echo "=== Result ==="
        echo $value
      else:
        echo "=== Execution Trace ==="
        VM.cu = compiled
        let value = VM.exec()
        echo "=== Final Result ==="
        echo $value
    else:
      let value = VM.exec(code, "<eval>")
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
