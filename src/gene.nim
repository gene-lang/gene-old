{.push warning[UnusedImport]: off.}
import os, tables
import ./commands/base
import ./commands/[run, eval, repl, help, parse, compile, gir, lsp, pipe, fmt]
import ./gene/vm/thread
import ./gene/types as gene_types
import ./gene/extension/c_api  # Link C API for extensions

{.pop.}

var CommandMgr = CommandManager(data: initTable[string, Command](), help: "")

# Initialize all commands
run.init(CommandMgr)
eval.init(CommandMgr)
repl.init(CommandMgr)
help.init(CommandMgr)
parse.init(CommandMgr)
compile.init(CommandMgr)
gir.init(CommandMgr)
lsp.init(CommandMgr)
pipe.init(CommandMgr)
fmt.init(CommandMgr)

proc main(): int =
  # Initialize thread pool for multi-threading support
  init_thread_pool()

  var args = command_line_params()
  
  if args.len == 0:
    # No arguments, show help
    let helpCommand = CommandMgr.lookup("help")
    if helpCommand != nil:
      let helpResult = helpCommand("help", @[])
      if helpResult.output.len > 0:
        echo helpResult.output
    return 0
  
  var cmd = args[0]
  let command_args = args[1 .. ^1]
  
  # Use safe lookup
  let handler = CommandMgr.lookup(cmd)
  if handler.isNil:
    echo "Error: Unknown command: ", cmd
    echo ""
    let helpHandler = CommandMgr.lookup("help")
    if helpHandler != nil:
      let helpResult = helpHandler("help", @[])
      if helpResult.output.len > 0:
        echo helpResult.output
    return 1
  
  # Execute the command
  let cmdResult = handler(cmd, command_args)
  if not cmdResult.success:
    if cmdResult.error.len > 0:
      echo "Error: ", cmdResult.error
    return 1
  elif cmdResult.output.len > 0:
    echo cmdResult.output
  return 0

when isMainModule:
  let exit_code = main()
  if gene_types.VM != nil:
    if existsEnv("GENE_DEEP_VM_FREE") and getEnv("GENE_DEEP_VM_FREE") == "1":
      gene_types.free_vm_ptr(gene_types.VM)
    else:
      gene_types.free_vm_ptr_fast(gene_types.VM)
    gene_types.VM = nil
  quit(exit_code)
