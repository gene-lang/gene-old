import std/[os, osproc, strutils, unittest]

suite "GeneClaw CLI mode":
  test "interactive CLI path works end to end":
    let script = absolutePath("example-projects/geneclaw/tests/run_cli_mode_tests.sh")
    check fileExists(script)

    let result = execCmdEx(script)
    check result.exitCode == 0
    if result.exitCode != 0:
      checkpoint(result.output)
    else:
      check result.output.contains("ok")
