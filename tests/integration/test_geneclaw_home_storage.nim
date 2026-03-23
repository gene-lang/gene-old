import std/[os, osproc, strutils, unittest]

suite "GeneClaw home storage":
  test "serialized home config and workspace survive restart":
    let script = absolutePath("example-projects/geneclaw/tests/run_home_storage_tests.sh")
    check fileExists(script)

    let result = execCmdEx(script)
    check result.exitCode == 0
    if result.exitCode != 0:
      checkpoint(result.output)
    else:
      check result.output.contains("ok")
