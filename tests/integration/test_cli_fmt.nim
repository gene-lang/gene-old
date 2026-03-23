import unittest, os, osproc, streams
import std/tempfiles
import gene/formatter

proc run_fmt_with_stdin(command: string, input: string): tuple[output: string, exit_code: int] =
  let gene_bin = absolutePath("bin/gene")
  let process = startProcess(
    gene_bin,
    args = @[command],
    options = {poUsePath}
  )

  process.inputStream.write(input)
  process.inputStream.close()

  result.output = process.outputStream.readAll()
  result.exit_code = waitForExit(process)
  close(process)

suite "Fmt CLI":
  test "format alias formats files in place":
    let root = createTempDir("gene_fmt_cli_alias_", "")
    let source_path = root / "sample.gene"
    let gene_bin = absolutePath("bin/gene")

    writeFile(source_path, "(var x 1)\n  (println x)\n")

    defer:
      if dirExists(root):
        removeDir(root)

    let result = execCmdEx(gene_bin.quoteShell & " format " & source_path.quoteShell)
    check result.exitCode == 0
    check readFile(source_path) == "(var x 1)\n(println x)\n"

  test "fmt reads source from stdin when piped":
    let input = "(var x 1)\n  (println x)"
    let result = run_fmt_with_stdin("fmt", input)

    check result.exit_code == 0
    check result.output == "(var x 1)\n(println x)"

  test "format alias reads source from stdin when piped":
    let input = "(var x 1)\n  (println x)"
    let result = run_fmt_with_stdin("format", input)

    check result.exit_code == 0
    check result.output == "(var x 1)\n(println x)"

  test "canonical example source round-trips unchanged":
    let source = readFile("examples/full.gene")
    check format_source(source) == source
