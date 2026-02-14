import os, parseopt

import ../gene/formatter
import ./base

const
  DEFAULT_COMMAND = "fmt"
  COMMANDS = @[DEFAULT_COMMAND]

type
  FmtOptions = object
    help: bool
    check: bool
    files: seq[string]

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("fmt [--check] <file.gene> [...]: format Gene source files")
  manager.add_help("  --check: verify canonical formatting without modifying files")

let short_no_val = {'h'}
let long_no_val = @["help", "check"]

let help_text = """
Usage: gene fmt [options] <file.gene>...

Format Gene source files to canonical style based on examples/full.gene conventions.

Options:
  -h, --help      Show this help message
  --check         Check formatting only (non-zero exit if any file is not canonical)

Examples:
  gene fmt file.gene
  gene fmt --check file.gene
  gene fmt file.gene --check
"""

proc parse_args(args: seq[string]): tuple[options: FmtOptions, err: string] =
  var options: FmtOptions

  for kind, key, _ in get_opt(args, short_no_val, long_no_val):
    case kind
    of cmdArgument:
      options.files.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        options.help = true
      of "check":
        options.check = true
      else:
        return (options, "Unknown option: " & key)
    of cmdEnd:
      discard

  (options, "")

proc format_one_file(path: string, check_only: bool): CommandResult =
  if not fileExists(path):
    return failure("File not found: " & path)

  let source = readFile(path)
  let formatted = format_source(source)
  let normalized = normalize_newlines(source)

  if check_only:
    if formatted != normalized:
      return failure("File is not canonically formatted: " & path)
    return success()

  if formatted != normalized:
    writeFile(path, formatted)

  success()

proc handle*(cmd: string, args: seq[string]): CommandResult =
  let parsed = parse_args(args)
  let options = parsed.options

  if parsed.err.len > 0:
    return failure(parsed.err)

  if options.help:
    return success(help_text)

  if options.files.len == 0:
    return failure("No input files provided")

  for path in options.files:
    let r = format_one_file(path, options.check)
    if not r.success:
      return r

  if options.check:
    return success("All files are canonically formatted")

  success()
