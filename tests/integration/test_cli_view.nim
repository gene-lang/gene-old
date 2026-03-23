import strutils, unittest

import commands/view as view_command

suite "View CLI":
  test "view help renders usage":
    let result = view_command.handle("view", @["--help"])
    check result.success
    check result.output.contains("Usage: gene view <file>")
    check result.output.contains("Esc")
    check result.output.contains("Tab")
    check result.output.contains("external editor")
    check result.output.contains("Ctrl-F")
    check result.output.contains("Ctrl-Shift-F")
    check result.output.contains("Ctrl-E")
    check result.output.contains("Type digits/text")
    check result.output.contains("F2")
    check result.output.contains("F5")

  test "view rejects missing file":
    let result = view_command.handle("view", @["tmp/does_not_exist.gene"])
    check not result.success
    check result.error.contains("not found")

  test "view rejects extra arguments":
    let result = view_command.handle("view", @["a.gene", "b.gene"])
    check not result.success
    check result.error.contains("exactly one file path")
