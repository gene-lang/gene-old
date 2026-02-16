import parseopt, strutils, os
import ../gene/types
import ../gene/vm
import ../gene/compiler
import ./base

const DEFAULT_COMMAND = "pipe"
const COMMANDS = @[DEFAULT_COMMAND]

type
  PipeOptions = ref object
    debugging: bool
    trace: bool
    trace_instruction: bool
    compile: bool
    help: bool
    quote_str: bool
    filter: bool
    type_check: bool
    native_tier: NativeCompileTier
    native_code: bool
    code: string

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("pipe <code>: process stdin line-by-line with <code>")
  manager.add_help("  Each line is available as $line")
  manager.add_help("  -d, --debug: enable debug output")
  manager.add_help("  --trace: enable execution tracing")
  manager.add_help("  --compile: show compilation details")
  manager.add_help("  --quote-str: output strings with quotes")
  manager.add_help("  --filter: treat code as predicate, output $line when true")
  manager.add_help("  --no-type-check: disable static type checking (alias: --no-typecheck)")
  manager.add_help("  --native-code: enable native code execution (alias for --native-tier guarded)")
  manager.add_help("  --native-tier <never|guarded|fully-typed>: set native compilation policy")

let short_no_val = {'d', 'h'}
let long_no_val = @[
  "trace",
  "trace-instruction",
  "compile",
  "help",
  "quote-str",
  "filter",
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

proc parse_options(args: seq[string]): PipeOptions =
  result = PipeOptions(type_check: true, native_tier: NctNever)
  var code_parts: seq[string] = @[]

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
      of "trace":
        result.trace = true
      of "trace-instruction":
        result.trace_instruction = true
      of "compile":
        result.compile = true
      of "h", "help":
        result.help = true
      of "quote-str":
        result.quote_str = true
      of "filter":
        result.filter = true
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
      else:
        echo "Unknown option: ", key
    of cmdEnd:
      discard

  result.code = code_parts.join(" ")

proc set_line_variable(line: string) =
  ## Set the $line variable in global and gene namespaces
  if App == NIL or App.kind != VkApplication:
    init_app_and_vm()
    if App == NIL or App.kind != VkApplication:
      return

  let line_value = line.to_value()
  App.app.gene_ns.ref.ns["line".to_key()] = line_value
  App.app.global_ns.ref.ns["line".to_key()] = line_value

proc handle*(cmd: string, args: seq[string]): CommandResult =
  let options = parse_options(args)

  if options.help:
    return success("""Gene Pipe Command - Line-by-line stream processing

Usage: gene pipe [options] '<code>'
       gene pipe [options] <file>

Process stdin line-by-line, executing Gene code for each line.
The current line is available as $line.
Code can be provided inline or read from a file (supports shebang).

Options:
  -h, --help              Show this help message
  -d, --debug             Enable debug output
  --trace                 Enable execution tracing
  --compile               Show compilation details
  --quote-str             Output strings with quotes (for Gene-parseable output)
  --filter                Treat code as predicate; output $line when true
  --no-type-check         Disable static type checking (alias: --no-typecheck)
  --native-code           Enable native code execution (alias for --native-tier guarded)
  --native-tier <tier>    Native tier: never | guarded | fully-typed

Examples:
  # Output lines as-is
  cat file.txt | gene pipe '$line'

  # Filter lines (nil results are skipped)
  cat log.txt | gene pipe '(if ($line == "keep") $line)'

  # String interpolation
  ls | gene pipe '#"File: #{$line}"'

  # Process numbers
  seq 1 5 | gene pipe '(* $line/.to_i 2)'

  # Get line length
  cat file.txt | gene pipe '($line .size)'

  # Output with quotes for Gene-parseable data
  cat file.txt | gene pipe --quote-str '$line'

  # Filter lines using predicate (outputs $line when true)
  cat log.txt | gene pipe --filter '($line/.size > 10)'
  cat data.txt | gene pipe --filter '($line == "keep")'

  # Create executable script with shebang
  echo '#!/usr/bin/env gene pipe' > filter.gene
  echo '($line .size)' >> filter.gene
  chmod +x filter.gene
  cat file.txt | ./filter.gene

Notes:
  - Nil results are skipped (enables filtering)
  - Exits with non-zero status on first error
  - Lines are processed in streaming fashion (no buffering)
""")

  setup_logger(options.debugging)

  var code = options.code

  if code.len == 0:
    return failure("No code provided. Usage: gene pipe '<code>'")

  # Check if code is a file path - if so, read code from the file
  if fileExists(code):
    try:
      let file_content = readFile(code)
      var lines: seq[string] = @[]
      var first_line = true
      for line in file_content.splitLines():
        # Skip shebang line (only first line)
        if first_line and line.startsWith("#!"):
          first_line = false
          continue
        first_line = false
        # Skip empty lines
        if line.len == 0:
          continue
        let stripped = line.strip()
        # Skip comment-only lines (# but not #" or #< which are string interpolation/block comments)
        if stripped.startsWith("#") and not stripped.startsWith("#\"") and not stripped.startsWith("#<"):
          continue
        lines.add(line)
      code = lines.join("\n")
      if code.len == 0:
        return failure("No code found in file (only shebang/comments)")
    except IOError as e:
      return failure("Failed to read file: " & e.msg)

  # If filter mode, wrap the expression to output $line when true
  if options.filter:
    code = "(if " & code & " $line)"

  # Initialize VM
  init_app_and_vm()
  VM.native_tier = options.native_tier
  VM.native_code = options.native_tier != NctNever
  VM.type_check = options.type_check
  init_stdlib()
  set_program_args("<pipe>", @[])

  # Compile code once before processing lines
  var compiled: CompilationUnit
  try:
    compiled = parse_and_compile(code, type_check = options.type_check)

    if options.compile or options.debugging:
      echo "=== Compiled Code ==="
      for i, instr in compiled.instructions:
        echo i, ": ", instr
      echo ""
  except CatchableError as e:
    return failure("Compilation error: " & e.msg)

  # Enable tracing if requested
  if options.trace or options.trace_instruction:
    VM.trace = true

  # Process stdin line by line
  var line: string
  var line_num = 0

  while stdin.readLine(line):
    line_num += 1

    # Set $line variable
    set_line_variable(line)

    # Execute the compiled code
    try:
      # Initialize frame if needed
      if VM.frame == nil:
        let ns = new_namespace(App.app.global_ns.ref.ns, "<pipe>")
        ns["__module_name__".to_key()] = "<pipe>".to_value()
        ns["__is_main__".to_key()] = TRUE
        ns["gene".to_key()] = App.app.gene_ns
        ns["genex".to_key()] = App.app.genex_ns
        VM.frame = new_frame(ns)

      VM.cu = compiled
      let exec_result = VM.exec()

      # Print result if not nil (enables filtering)
      if exec_result.kind != VkNil:
        # Output strings without quotes unless --quote-str is specified
        if exec_result.kind == VkString and not options.quote_str:
          echo exec_result.str
        else:
          echo $exec_result

    except CatchableError as e:
      stderr.writeLine("Error at line ", line_num, ": ", e.msg)
      return failure("")

  return success()

when isMainModule:
  let cmd = DEFAULT_COMMAND
  let args: seq[string] = @[]
  let result = handle(cmd, args)
  if not result.success:
    echo "Failed with error: " & result.error
