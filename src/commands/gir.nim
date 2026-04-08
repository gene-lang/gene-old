import os, strutils, times

import ../gene/gir
import ../gene/types
import ./base
import ./listing_utils

const COMMAND = "gir"
const HELP_TEXT = """
Usage: gene gir show <file>

Display a human-readable listing of the instructions stored in an existing GIR file.

Examples:
  gene gir show build/examples/hello_world.gir
"""

proc appendInstructions(lines: var seq[string], instructions: openArray[Instruction], indent: int) =
  let indentStr = "  ".repeat(indent)
  var i = 0
  while i < instructions.len:
    let inst = instructions[i]
    var line = formatInstruction(inst, i, "pretty", true)
    if indent > 0:
      line = indentStr & line
    lines.add(line)

    if inst.kind == IkFunction:
      # Check arg0 directly (module init functions)
      if inst.arg0.kind == VkFunctionDef:
        let info = to_function_def_info(inst.arg0)
        if info.compiled_body.kind == VkCompiledUnit and info.compiled_body.ref.cu != nil:
          lines.add(indentStr & "  function body:")
          appendInstructions(lines, info.compiled_body.ref.cu.instructions, indent + 1)
      # Check next IkData instruction
      elif i + 1 < instructions.len:
        let dataInst = instructions[i + 1]
        if dataInst.kind == IkData and dataInst.arg0.kind == VkFunctionDef:
          let info = to_function_def_info(dataInst.arg0)
          if info.compiled_body.kind == VkCompiledUnit and info.compiled_body.ref.cu != nil:
            lines.add(indentStr & "  function body:")
            appendInstructions(lines, info.compiled_body.ref.cu.instructions, indent + 1)
    inc i

proc handle_show(file_path: string): CommandResult =
  if file_path.len == 0:
    return failure("Missing GIR file path. Usage: gene gir show <file>")
  if not fileExists(file_path):
    return failure("GIR file not found: " & file_path)

  try:
    let gir_file = load_gir_file(file_path)
    var lines: seq[string] = @[]
    let timestampStr =
      block:
        let ts = gir_file.header.timestamp
        if ts == 0:
          "unknown"
        else:
          let dt = local(fromUnix(ts))
          format(dt, "yyyy-MM-dd HH:mm:ss")

    lines.add("GIR File: " & file_path)
    lines.add("Compiler: " & gir_file.header.compiler_version)
    lines.add("VM ABI  : " & gir_file.header.vm_abi)
    lines.add("Version : " & $gir_file.header.version)
    lines.add("Flags   : debug=" & $gir_file.header.debug & ", published=" & $gir_file.header.published)
    lines.add("Source  : hash=0x" & gir_file.header.source_hash.int.toHex(8))
    lines.add("Timestamp: " & timestampStr)
    lines.add("")

    if gir_file.constants.len > 0:
      lines.add("Constants (" & $gir_file.constants.len & "):")
      for i, value in gir_file.constants:
        lines.add("  [" & $i & "] " & formatValue(value))
      lines.add("")

    if gir_file.symbols.len > 0:
      lines.add("Symbols (" & $gir_file.symbols.len & "):")
      for i, value in gir_file.symbols:
        lines.add("  [" & $i & "] " & value)
      lines.add("")

    lines.add("Instructions (" & $gir_file.instructions.len & "):")
    appendInstructions(lines, gir_file.instructions, 0)

    return success(lines.join("\n"))
  except types.Exception as e:
    return failure(e.msg)
  except IOError as e:
    return failure("Failed to read GIR file: " & file_path & " (" & e.msg & ")")
  except CatchableError as e:
    return failure("Failed to load GIR file: " & e.msg)

proc handle*(cmd: string, args: seq[string]): CommandResult =
  if args.len == 0:
    return success(HELP_TEXT.strip())

  let subcmd = args[0].toLowerAscii()
  case subcmd
  of "-h", "--help", "help":
    return success(HELP_TEXT.strip())
  of "show", "visualize":
    let file_path = if args.len > 1: args[1] else: ""
    return handle_show(file_path)
  else:
    return failure("Unknown subcommand for gir: " & subcmd)

proc init*(manager: CommandManager) =
  manager.register(COMMAND, handle)
  manager.add_help("  gir show <file>  Display instructions from a GIR file")
