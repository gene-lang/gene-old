import strutils, os, tables, terminal
import ../gene/types
import ../gene/vm
import ../gene/parser
import ../gene/serdes
import ./base

const DEFAULT_COMMAND = "deser"
const COMMANDS = @[DEFAULT_COMMAND, "deserialize"]

type
  DeserOptions = object
    help: bool
    debugging: bool
    print_type: bool
    format: string  # "pretty" (default), "compact", "gene"
    gene_format: bool
    code: string
    files: seq[string]
    project: string

proc handle*(cmd: string, args: seq[string]): CommandResult

let short_no_val = {'h', 'd', 'p'}  # Note: 'e' takes a value, so NOT listed here
let long_no_val = @[
  "help",
  "debug",
  "print-type",
  "gene",
]

let help_text = """
Usage: gene deser|deserialize [options] [<file>...]

Deserialize Gene serialization text back into runtime objects.

Runs in a full VM environment so class references and namespaces
from the current project can be resolved.

Input sources (priority order):
  1. -e <text>    Deserialize inline text
  2. <file>       Read and deserialize file contents
  3. stdin        Read from piped input

Options:
  -h, --help              Show this help message
  -e, --eval <text>       Deserialize the given text string
  -f, --format <format>   Output format: pretty (default), compact, gene
  --gene                  Shorthand for --format gene
  --project <path>        Load project context before deserializing
  -p, --print-type        Also print the type/kind of the result
  -d, --debug             Enable debug logging

Examples:
  gene deser state.gene
  echo '(gene/serialization 42)' | gene deser
  gene deser -e '(gene/serialization {^key "value"})'
  gene deserialize -e '(gene/serialization (FunctionRef ^path "run" ^module "app/main.gene"))'
  gene deser --gene home/state/system_prompt.gene

Notes:
  - Named runtime refs use ^path and optional ^module properties.
  - Anonymous inline Instance payloads are not supported.
  - Custom runtime values deserialize through Instance payloads only when the
    referenced class defines both serialize and deserialize hooks.
"""

proc parse_args(args: seq[string]): DeserOptions =
  result.format = "pretty"

  if args.len == 0:
    return

  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "-h" or arg == "--help":
      result.help = true
    elif arg == "-d" or arg == "--debug":
      result.debugging = true
    elif arg == "-p" or arg == "--print-type":
      result.print_type = true
    elif arg == "--gene":
      result.gene_format = true
    elif arg == "-e" or arg == "--eval":
      inc i
      if i >= args.len:
        stderr.writeLine("Error: -e requires a value")
        quit(1)
      result.code = args[i]
    elif arg == "-f" or arg == "--format":
      inc i
      if i >= args.len:
        stderr.writeLine("Error: --format requires a value")
        quit(1)
      let fmt = args[i]
      if fmt in ["pretty", "compact", "gene"]:
        result.format = fmt
      else:
        stderr.writeLine("Error: Invalid format '" & fmt & "'. Must be: pretty, compact, or gene")
        quit(1)
    elif arg == "--project":
      inc i
      if i >= args.len:
        stderr.writeLine("Error: --project requires a value")
        quit(1)
      result.project = args[i]
    elif arg.startsWith("-"):
      stderr.writeLine("Error: Unknown option: " & arg)
      quit(1)
    else:
      result.files.add(arg)
    inc i

  if result.gene_format:
    result.format = "gene"

proc format_deserialized(value: Value, format: string, indent: int = 0): string =
  ## Format a deserialized value for display
  let spaces = "  ".repeat(indent)
  case value.kind
  of VkNil:
    return spaces & "nil"
  of VkBool:
    return spaces & (if value == TRUE: "true" else: "false")
  of VkInt:
    return spaces & $value.to_int()
  of VkFloat:
    return spaces & $value.to_float()
  of VkChar:
    return spaces & "'" & $chr((value.raw and 0xFF).int) & "'"
  of VkString:
    if format == "gene":
      result = spaces & "\""
      for ch in value.str:
        case ch
        of '"': result &= "\\\""
        of '\\': result &= "\\\\"
        of '\n': result &= "\\n"
        of '\r': result &= "\\r"
        of '\t': result &= "\\t"
        else: result &= ch
      result &= "\""
    else:
      return spaces & value.str
  of VkSymbol:
    return spaces & value.str
  of VkComplexSymbol:
    return spaces & value.ref.csymbol.join("/")
  of VkArray:
    if array_data(value).len == 0:
      return spaces & "[]"
    if format == "compact":
      result = spaces & "["
      for i, item in array_data(value):
        if i > 0: result &= " "
        result &= format_deserialized(item, format)
      result &= "]"
    else:
      result = spaces & "[\n"
      for item in array_data(value):
        result &= format_deserialized(item, format, indent + 1) & "\n"
      result &= spaces & "]"
  of VkMap:
    if map_data(value).len == 0:
      return spaces & "{}"
    if format == "compact":
      result = spaces & "{"
      var first = true
      for k, v in map_data(value):
        if not first: result &= " "
        let symbol_value = cast[Value](k)
        let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
        result &= "^" & get_symbol(symbol_index.int) & " " & format_deserialized(v, format)
        first = false
      result &= "}"
    else:
      result = spaces & "{\n"
      for k, v in map_data(value):
        let symbol_value = cast[Value](k)
        let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
        result &= spaces & "  ^" & get_symbol(symbol_index.int) & " " & format_deserialized(v, format) & "\n"
      result &= spaces & "}"
  of VkGene:
    result = spaces & "(" & format_deserialized(value.gene.type, "compact")
    for k, v in value.gene.props:
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      result &= " ^" & get_symbol(symbol_index.int) & " " & format_deserialized(v, "compact")
    if value.gene.children.len > 0:
      if format == "compact":
        for child in value.gene.children:
          result &= " " & format_deserialized(child, format)
      else:
        result &= "\n"
        for child in value.gene.children:
          result &= format_deserialized(child, format, indent + 1) & "\n"
        result &= spaces
    result &= ")"
  of VkInstance:
    result = spaces & "<Instance of " & value.instance_class.name & "> {\n"
    for k, v in instance_props(value):
      let symbol_value = cast[Value](k)
      let symbol_index = cast[uint64](symbol_value) and PAYLOAD_MASK
      result &= spaces & "  " & get_symbol(symbol_index.int) & ": " & format_deserialized(v, "compact") & "\n"
    result &= spaces & "}"
  of VkCustom:
    let class_name =
      if value.ref != nil and value.ref.custom_class != nil and value.ref.custom_class.name.len > 0:
        value.ref.custom_class.name
      else:
        "Custom"
    return spaces & "<Custom " & class_name & ">"
  of VkClass:
    return spaces & "<Class " & value.ref.class.name & ">"
  of VkNamespace:
    return spaces & "<Namespace>"
  of VkFunction:
    return spaces & "<Function " & value.ref.fn.name & ">"
  else:
    return spaces & $value

proc kind_name(value: Value): string =
  ## Human-readable type name
  case value.kind
  of VkNil: "Nil"
  of VkBool: "Bool"
  of VkInt: "Int"
  of VkFloat: "Float"
  of VkChar: "Char"
  of VkString: "String"
  of VkSymbol: "Symbol"
  of VkArray: "Array"
  of VkMap: "Map"
  of VkGene: "Gene"
  of VkInstance: "Instance of " & value.instance_class.name
  of VkCustom:
    if value.ref != nil and value.ref.custom_class != nil and value.ref.custom_class.name.len > 0:
      "Custom " & value.ref.custom_class.name
    else:
      "Custom"
  of VkClass: "Class"
  of VkNamespace: "Namespace"
  of VkFunction: "Function"
  else: $value.kind

proc do_deserialize(input: string, source: string, options: DeserOptions): CommandResult =
  try:
    let deserialized = deserialize(input)
    echo format_deserialized(deserialized, options.format)
    if options.print_type:
      echo "Type: " & kind_name(deserialized)
    return success()
  except ParseError as e:
    stderr.writeLine("Parse error in " & source & ": " & e.msg)
    return failure(e.msg)
  except CatchableError as e:
    stderr.writeLine("Deserialization error in " & source & ": " & e.msg)
    return failure(e.msg)

proc handle*(cmd: string, args: seq[string]): CommandResult =
  let options = parse_args(args)
  setup_logger(options.debugging)

  if options.help:
    echo help_text
    return success()

  # Initialize VM for class/namespace resolution
  init_app_and_vm()
  init_stdlib()
  set_program_args("<deser>", @[])

  # Load project context if requested
  if options.project != "":
    let project_path = if options.project == ".": getCurrentDir() else: options.project
    let package_file = project_path / "package.gene"
    if fileExists(package_file):
      try:
        let code = readFile(package_file)
        discard VM.exec(code, package_file)
      except CatchableError as e:
        stderr.writeLine("Warning: Could not load project package: " & e.msg)

  # Determine input source
  if options.code != "":
    # From -e flag
    return do_deserialize(options.code, "<eval>", options)
  elif options.files.len > 0:
    # From file arguments
    for file in options.files:
      if not fileExists(file):
        stderr.writeLine("Error: File not found: " & file)
        return failure("File not found: " & file)

      let content = readFile(file)
      if options.files.len > 1:
        echo "=== " & file & " ==="

      let file_result = do_deserialize(content, file, options)
      if not file_result.success:
        return file_result

    return success()
  else:
    # From stdin
    if stdin.isatty():
      stderr.writeLine("Error: No input provided. Use -e for text, provide a file, or pipe input.")
      stderr.writeLine("Run 'gene deser --help' for usage.")
      return failure("No input")

    var lines: seq[string] = @[]
    var line: string
    while stdin.readLine(line):
      lines.add(line)

    if lines.len == 0:
      stderr.writeLine("Error: Empty input from stdin.")
      return failure("Empty input")

    return do_deserialize(lines.join("\n"), "<stdin>", options)

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("  deser    Deserialize Gene serialization text (alias: deserialize)")
