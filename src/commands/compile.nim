import parseopt, strutils, os, terminal, streams, json, algorithm, tables
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
    format: string  # "pretty", "compact", "bytecode", "gir", "ai-metadata"
    show_addresses: bool
    out_dir: string  # Output directory for GIR files
    force: bool      # Force rebuild even if cache is up-to-date
    emit_debug: bool # Include debug info in GIR
    eager_functions: bool
    type_check: bool
    pending_eval: bool

proc handle*(cmd: string, args: seq[string]): CommandResult

proc module_type_kind_name(kind: ModuleTypeKind): string =
  case kind
  of MtkNamespace:
    "namespace"
  of MtkClass:
    "class"
  of MtkEnum:
    "enum"
  of MtkInterface:
    "interface"
  of MtkAlias:
    "alias"
  of MtkObject:
    "object"
  else:
    "unknown"

proc type_desc_kind_name(kind: TypeDescKind): string =
  case kind
  of TdkAny:
    "any"
  of TdkNamed:
    "named"
  of TdkApplied:
    "applied"
  of TdkUnion:
    "union"
  of TdkFn:
    "fn"
  of TdkVar:
    "var"

proc json_type_id_array(type_ids: seq[TypeId]): JsonNode =
  result = newJArray()
  for type_id in type_ids:
    result.add(%int(type_id))

proc json_callable_param_array(params: seq[CallableParamDesc]): JsonNode =
  result = newJArray()
  for param in params:
    var node = newJObject()
    node["kind"] = %($param.kind)
    if param.keyword_name.len > 0:
      node["keyword_name"] = %param.keyword_name
    node["type_id"] = %int(param.type_id)
    result.add(node)

proc module_type_node_to_json(node: ModuleTypeNode): JsonNode =
  result = newJObject()
  result["name"] = %node.name
  result["kind"] = %module_type_kind_name(node.kind)
  var children = newJArray()
  for child in node.children:
    if child != nil:
      children.add(module_type_node_to_json(child))
  result["children"] = children

proc type_desc_to_json(type_id: TypeId, desc: TypeDesc): JsonNode =
  result = newJObject()
  result["id"] = %int(type_id)
  result["kind"] = %type_desc_kind_name(desc.kind)
  result["module_path"] = %desc.module_path
  case desc.kind
  of TdkNamed:
    result["name"] = %desc.name
  of TdkApplied:
    result["ctor"] = %desc.ctor
    result["args"] = json_type_id_array(desc.args)
  of TdkUnion:
    result["members"] = json_type_id_array(desc.members)
  of TdkFn:
    result["params"] = json_callable_param_array(desc.params)
    result["ret"] = %int(desc.ret)
    var effects = newJArray()
    for effect in desc.effects:
      effects.add(%effect)
    result["effects"] = effects
  of TdkVar:
    result["var_id"] = %int(desc.var_id)
  else:
    discard

proc value_name(value: Value): string =
  case value.kind
  of VkSymbol, VkString:
    value.str
  of VkComplexSymbol:
    if value.ref != nil and value.ref.csymbol.len > 0:
      value.ref.csymbol[^1]
    else:
      ""
  else:
    ""

proc callable_name_from_input(input: Value): string =
  if input.kind != VkGene or input.gene == nil or input.gene.children.len == 0:
    return "<anonymous>"
  let first = input.gene.children[0]
  if first.kind == VkArray:
    return "<anonymous>"
  let extracted = value_name(first)
  if extracted.len == 0:
    return "<anonymous>"
  extracted

proc callable_arg_names_from_input(input: Value): seq[string] =
  if input.kind != VkGene or input.gene == nil or input.gene.children.len == 0:
    return @[]

  let first = input.gene.children[0]
  var args = NIL
  if first.kind == VkArray:
    args = first
  elif input.gene.children.len > 1 and input.gene.children[1].kind == VkArray:
    args = input.gene.children[1]

  if args.kind != VkArray:
    return @[]

  let items = array_data(args)
  var i = 0
  while i < items.len:
    let item = items[i]
    if item.kind == VkSymbol and item.str.ends_with(":"):
      result.add(item.str[0..^2])
      i += 2
      continue

    let extracted = value_name(item)
    if extracted.len > 0:
      result.add(extracted)
    else:
      result.add("arg" & $result.len)
    inc i

proc callable_info_to_json(info: FunctionDefInfo): JsonNode =
  result = newJObject()
  let arg_names = callable_arg_names_from_input(info.input)
  let param_count = max(arg_names.len, info.type_expectation_ids.len)
  var params = newJArray()
  var param_type_ids = newJArray()
  var typed = info.return_type_id != NO_TYPE_ID

  for i in 0..<param_count:
    let param_name =
      if i < arg_names.len: arg_names[i]
      else: "arg" & $i
    let type_id =
      if i < info.type_expectation_ids.len: info.type_expectation_ids[i]
      else: NO_TYPE_ID
    if type_id != NO_TYPE_ID:
      typed = true
    var param = newJObject()
    param["name"] = %param_name
    param["type_id"] = %int(type_id)
    params.add(param)
    param_type_ids.add(%int(type_id))

  result["name"] = %callable_name_from_input(info.input)
  result["typed"] = %typed
  result["params"] = params
  result["param_type_ids"] = param_type_ids
  result["return_type_id"] = %int(info.return_type_id)

  if info.input.kind == VkGene and info.input.gene != nil and info.input.gene.trace != nil:
    result["line"] = %info.input.gene.trace.line
    result["column"] = %info.input.gene.trace.column

proc metadata_json(compiled: CompilationUnit, source_name: string): string =
  var root = newJObject()
  root["format"] = %"ai-metadata"
  root["source"] = %source_name
  root["module_path"] =
    %(if compiled.module_path.len > 0: compiled.module_path else: source_name)
  root["instruction_count"] = %compiled.instructions.len

  var exports = newJArray()
  for name in compiled.module_exports:
    exports.add(%name)
  root["module_exports"] = exports

  var imports = newJArray()
  for name in compiled.module_imports:
    imports.add(%name)
  root["module_imports"] = imports

  var module_types = newJArray()
  for node in compiled.module_types:
    if node != nil:
      module_types.add(module_type_node_to_json(node))
  root["module_types"] = module_types

  var descriptors = newJArray()
  for i, desc in compiled.type_descriptors:
    descriptors.add(type_desc_to_json(i.TypeId, desc))
  root["type_descriptors"] = descriptors

  if compiled.type_registry != nil:
    root["type_registry_module_path"] = %compiled.type_registry.module_path

  var alias_names: seq[string] = @[]
  for name, _ in compiled.type_aliases:
    alias_names.add(name)
  alias_names.sort()
  var aliases = newJArray()
  for name in alias_names:
    var alias_entry = newJObject()
    alias_entry["name"] = %name
    alias_entry["type_id"] = %int(compiled.type_aliases[name])
    aliases.add(alias_entry)
  root["type_aliases"] = aliases

  var callables = newJArray()
  for inst in compiled.instructions:
    if inst.kind != IkFunction:
      continue
    if inst.arg0.kind != VkFunctionDef:
      continue
    let info = inst.arg0.ref.function_def
    if info == nil:
      continue
    callables.add(callable_info_to_json(info))
  root["callables"] = callables

  root.pretty()

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
  -f, --format <format>   Output format: pretty (default), compact, bytecode, gir, ai-metadata
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
      if result.pending_eval:
        result.code = key
        result.pending_eval = false
      else:
        result.files.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        result.help = true
      of "a", "addresses":
        result.show_addresses = true
      of "e", "eval":
        if value.len > 0:
          result.code = value
        else:
          result.pending_eval = true
      of "f", "format":
        if value == "":
          stderr.writeLine("Error: Format option requires a value")
          quit(1)
        elif value in ["pretty", "compact", "bytecode", "gir", "ai-metadata"]:
          result.format = value
        else:
          stderr.writeLine("Error: Invalid format '" & value & "'. Must be: pretty, compact, bytecode, gir, or ai-metadata")
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
  var metadata_outputs: seq[string] = @[]
  
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
      elif options.format == "ai-metadata":
        try:
          let compiled = parse_and_compile(code, file, options.eager_functions, options.type_check, module_mode = true, run_init = false)
          metadata_outputs.add(metadata_json(compiled, source_name))
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
    
    if options.format == "ai-metadata":
      return success(metadata_outputs.join("\n"))
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
    if options.format == "ai-metadata":
      let compiled = parse_and_compile(code, source_name, options.eager_functions, options.type_check, module_mode = false, run_init = false)
      return success(metadata_json(compiled, source_name))
    else:
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
