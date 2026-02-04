import parseopt, strutils, os, terminal, streams
import ../gene/types
import ../gene/parser
import ../gene/compiler
import ../gene/gir
import ./base
import ./listing_utils

const DEFAULT_COMMAND = "compile"

type
  CompileOptions = object
    help: bool
    files: seq[string]
    code: string
    format: string  # "pretty" (default), "compact", "bytecode", "gir"
    show_addresses: bool
    out_dir: string  # Output directory for GIR files
    force: bool      # Force rebuild even if cache is up-to-date
    emit_debug: bool # Include debug info in GIR
    eager_functions: bool
    type_check: bool

proc handle*(cmd: string, args: seq[string]): CommandResult

let short_no_val = {'h', 'a'}
let long_no_val = @[
  "help",
  "addresses",
  "force",
  "emit-debug",
  "eager",
  "no-typecheck",
  "no-type-check",
]

let help_text = """
Usage: gene compile [options] [<file>...]

Compile Gene code to bytecode or Gene IR (.gir) format.

Options:
  -h, --help              Show this help message
  -e, --eval <code>       Compile the given code string
  -f, --format <format>   Output format: pretty (default), compact, bytecode, gir
  -o, --out-dir <dir>     Output directory for GIR files (default: build/)
  -a, --addresses         Show instruction addresses
  --force                 Rebuild even if cache is up-to-date
  --emit-debug            Include debug info in GIR files
  --eager                 Eagerly compile function bodies (default for GIR output)
  --no-type-check         Disable static type checking (alias: --no-typecheck)

Examples:
  gene compile file.gene                  # Compile to build/file.gir
  gene compile -f pretty file.gene        # Display instructions
  gene compile -e "(+ 1 2)"               # Compile a code string
  gene compile -o out src/app.gene        # Output to out/src/app.gir
  gene compile --force file.gene          # Force recompilation
"""

proc parseArgs(args: seq[string]): CompileOptions =
  result.format = ""  # Will be set based on context
  result.out_dir = "build"
  result.type_check = true
  
  # Workaround: get_opt reads from command line when given empty args
  if args.len == 0:
    return
  
  for kind, key, value in get_opt(args, short_no_val, long_no_val):
    case kind
    of cmdArgument:
      result.files.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        result.help = true
      of "a", "addresses":
        result.show_addresses = true
      of "e", "eval":
        result.code = value
      of "f", "format":
        if value == "":
          stderr.writeLine("Error: Format option requires a value")
          quit(1)
        elif value in ["pretty", "compact", "bytecode", "gir"]:
          result.format = value
        else:
          stderr.writeLine("Error: Invalid format '" & value & "'. Must be: pretty, compact, bytecode, or gir")
          quit(1)
      of "o", "out-dir":
        result.out_dir = value
      of "force":
        result.force = true
      of "emit-debug":
        result.emit_debug = true
      of "eager":
        result.eager_functions = true
      of "no-typecheck", "no-type-check":
        result.type_check = false
      else:
        stderr.writeLine("Error: Unknown option: " & key)
        quit(1)
    of cmdEnd:
      discard
  
  # Default format based on context - moved after processing all arguments
  discard


proc handle*(cmd: string, args: seq[string]): CommandResult =
  var options = parseArgs(args)
  
  # Set default format if not specified
  if options.format == "":
    if options.files.len > 0:
      options.format = "gir"  # Default to GIR for files
    else:
      options.format = "pretty"  # Default to pretty for eval/stdin

  # Static/AOT direction: default to eager compilation for GIR output
  if options.format == "gir" and not options.eager_functions:
    options.eager_functions = true
  
  if options.help:
    echo help_text
    return success()
  
  var code: string
  var source_name: string
  
  if options.code != "":
    code = options.code
    source_name = "<eval>"
  elif options.files.len > 0:
    # Compile files
    for file in options.files:
      if not fileExists(file):
        stderr.writeLine("Error: File not found: " & file)
        quit(1)
      
      code = readFile(file)
      source_name = file
      
      # Check if GIR output is requested
      if options.format == "gir":
        let gir_path = get_gir_path(file, options.out_dir)

        # Check if recompilation is needed
        if not options.force and is_gir_up_to_date(gir_path, file):
          echo "Up-to-date: " & gir_path
          continue

        echo "Compiling: " & source_name & " -> " & gir_path

        try:
          # Use streaming compilation for better memory efficiency
          let stream = newFileStream(file, fmRead)
          if stream.isNil:
            stderr.writeLine("Error: Failed to open file: " & file)
            quit(1)
          defer: stream.close()
          let compiled = parse_and_compile(stream, file, options.eager_functions, options.type_check, module_mode = true, run_init = false)

          # Save to GIR file
          save_gir(compiled, gir_path, file, options.emit_debug)
          echo "Written: " & gir_path
        except ParseError as e:
          stderr.writeLine("Parse error in " & source_name & ": " & e.msg)
          quit(1)
        except ValueError as e:
          stderr.writeLine("Value error in " & source_name & ": " & e.msg)
          stderr.writeLine("Stack trace: " & e.getStackTrace())
          quit(1)
        except CatchableError as e:
          stderr.writeLine("Compilation error in " & source_name & ": " & e.msg)
          quit(1)
      else:
        # Display instructions
        echo "=== Compiling: " & source_name & " ==="
        
        try:
          let parsed = read_all(code)
          let compiled = compile(parsed, options.eager_functions)
          
          echo "Instructions (" & $compiled.instructions.len & "):"
          for i, inst in compiled.instructions:
            echo formatInstruction(inst, i, options.format, options.show_addresses)
          
          # TODO: Add matcher display when $ operator is available
          
          echo ""
        except ParseError as e:
          stderr.writeLine("Parse error in " & source_name & ": " & e.msg)
          quit(1)
        except CatchableError as e:
          stderr.writeLine("Compilation error in " & source_name & ": " & e.msg)
          quit(1)
    
    return success()
  else:
    # No code or files provided, try to read from stdin
    if not stdin.isatty():
      var lines: seq[string] = @[]
      var line: string
      while stdin.readLine(line):
        lines.add(line)
      if lines.len > 0:
        code = lines.join("\n")
        source_name = "<stdin>"
      else:
        stderr.writeLine("Error: No input provided. Use -e for code or provide a file.")
        quit(1)
    else:
      stderr.writeLine("Error: No input provided. Use -e for code or provide a file.")
      quit(1)
  
  # Compile single code string
  try:
    let parsed = read_all(code)
    let compiled = compile(parsed, options.eager_functions)
    
    echo "Instructions (" & $compiled.instructions.len & "):"
    for i, inst in compiled.instructions:
      echo formatInstruction(inst, i, options.format, options.show_addresses)
    
    # TODO: Add matcher display when $ operator is available
  except ParseError as e:
    stderr.writeLine("Parse error: " & e.msg)
    quit(1)
  except CatchableError as e:
    stderr.writeLine("Compilation error: " & e.msg)
    quit(1)
  
  return success()

proc init*(manager: CommandManager) =
  manager.register("compile", handle)
  manager.add_help("  compile  Compile Gene code and output bytecode")
