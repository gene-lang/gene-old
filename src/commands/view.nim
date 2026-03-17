import os, strutils, terminal

import ../gene/viewer/model
import ../gene/viewer/app
import ./base

const COMMAND = "view"
const HELP_TEXT = """
Usage: gene view <file>

Open a full-screen terminal viewer for a Gene data file or multi-form Gene log.

Navigation:
  Up/Down arrows        Move selection
  Page Up/Page Down     Move one screen
  Right arrow or Enter  Enter selected container
  Left arrow            Return to parent container
  Esc                   Return to root container
  Type digits/text      Jump by index or substring (0.5s buffer)
  F1                    Toggle help
  F2 or Ctrl-E          Open file in external editor
  F5                    Reload file from disk
  F10                   Quit viewer

Examples:
  gene view logs/app.gene
  gene view tmp/debug_log.gene
"""

proc handle*(cmd: string, args: seq[string]): CommandResult =
  if args.len == 0:
    return success(HELP_TEXT.strip())

  let first = args[0]
  if first in ["-h", "--help", "help"]:
    return success(HELP_TEXT.strip())

  if args.len > 1:
    return failure("view accepts exactly one file path")

  let file_path = first
  if not fileExists(file_path):
    return failure("Viewer file not found: " & file_path)

  if not stdin.isatty() or not stdout.isatty():
    return failure("gene view requires an interactive terminal")

  try:
    let doc = open_viewer_document(file_path)
    run_viewer(doc)
    return success()
  except ViewerError as e:
    return failure(e.msg)
  except IOError as e:
    return failure("Failed to read viewer file: " & e.msg)
  except CatchableError as e:
    return failure("Viewer startup failed: " & e.msg)

proc init*(manager: CommandManager) =
  manager.register(COMMAND, handle)
  manager.add_help("  view     Browse large Gene files in a terminal viewer")
