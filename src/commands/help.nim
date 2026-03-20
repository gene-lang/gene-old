import ./base

const DEFAULT_COMMAND = "help"
const COMMANDS = @[DEFAULT_COMMAND, "h", "--help", "-h"]

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("help [command]: show help for all commands or specific command")

proc handle*(cmd: string, args: seq[string]): CommandResult =
  var output = ""
  output &= "Gene Programming Language\n"
  output &= "Usage: gene <command> [options] [args]\n"
  output &= "\n"
  output &= "Commands:\n"
  output &= "  run      Execute a Gene file\n"
  output &= "  eval     Evaluate Gene code\n"
  output &= "  fmt      Format Gene source files (alias: format)\n"
  output &= "  pipe     Process stdin line-by-line\n"
  output &= "  repl     Start interactive REPL\n"
  output &= "  parse    Parse Gene code and output AST\n"
  output &= "  compile  Compile Gene code and output bytecode\n"
  output &= "  gir      Show instructions from a GIR file\n"
  output &= "  view     Browse a Gene file in a terminal viewer\n"
  output &= "  deps     Manage package dependencies\n"
  output &= "  lsp      Start Language Server Protocol server\n"
  output &= "  run-examples  Run function examples declared in source\n"
  output &= "  deser    Deserialize Gene serialization text (alias: deserialize)\n"
  output &= "  help     Show this help message\n"
  output &= "\n"
  output &= "Examples:\n"
  output &= "  gene run script.gene    # Run a Gene file\n"
  output &= "  gene eval '(+ 1 2)'     # Evaluate an expression\n"
  output &= "  gene fmt file.gene      # Format a Gene file\n"
  output &= "  gene format file.gene   # Same as gene fmt\n"
  output &= "  gene repl               # Start interactive mode\n"
  output &= "  gene parse file.gene    # Parse and show AST\n"
  output &= "  gene view log.gene      # Browse a large Gene file interactively\n"
  output &= "  gene deps install       # Install dependencies\n"
  output &= "  gene run-examples file.gene  # Run ^examples in a file\n"
  
  return success(output)

when isMainModule:
  let cmd = DEFAULT_COMMAND
  let args: seq[string] = @[]
  let result = handle(cmd, args)
  if result.success:
    echo result.output
  else:
    echo "Failed with error: " & result.error
