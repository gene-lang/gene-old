import std/[unittest, os, osproc, strutils, algorithm]

proc collectSuiteFiles(): seq[string] =
  for path in walkDirRec("tests/suite"):
    if path.endsWith(".gene") and extractFilename(path).startsWith("test_"):
      result.add(path)
  result.sort(cmp[string])

proc runCmd(cmd: string): tuple[code: int, output: string] =
  let r = execCmdEx(cmd)
  (r.exitCode, r.output)

suite "Gene suite files":
  test "run all tests/suite/*.gene":
    let (buildCode, buildOut) = runCmd("nim c -o:bin/gene src/gene.nim")
    check buildCode == 0
    if buildCode != 0:
      checkpoint("build output:\n" & buildOut)
    else:
      let files = collectSuiteFiles()
      check files.len > 0

      for file in files:
        let (code, output) = runCmd("bin/gene run " & quoteShell(file))
        check code == 0
        check output.contains("ALL TESTS PASSED")
        check not output.contains("SOME TESTS FAILED")
