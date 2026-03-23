import os, osproc, streams, strformat, strutils, unittest

proc run_gene(args: seq[string], input = ""): tuple[output: string, exit_code: int] =
  let gene_bin = absolutePath("bin/gene")
  let process = startProcess(
    gene_bin,
    args = args,
    options = {poUsePath, poStdErrToStdOut}
  )

  if input.len > 0:
    process.inputStream.write(input)
  process.inputStream.close()

  result.output = process.outputStream.readAll()
  result.exit_code = waitForExit(process)
  close(process)

suite "Deser CLI":
  test "help text documents alias and unsupported inline instances":
    let result = run_gene(@["deser", "--help"])
    check result.exit_code == 0
    check result.output.contains("Usage: gene deser|deserialize")
    check result.output.contains("Anonymous inline Instance payloads are not supported.")

  test "deserialize alias reads canonical runtime text":
    let result = run_gene(@["deserialize", "-e", "(gene/serialization [1 2 3])"])
    check result.exit_code == 0
    check result.output.contains("[")
    check result.output.contains("1")
    check result.output.contains("3")

  test "legacy inline Instance payloads are rejected":
    let module_path = absolutePath("tests/fixtures/serdes_objects.gene")
    let payload = fmt"""(gene/serialization (Instance (ClassRef ^path "ExportedThing" ^module "{module_path}") {{^name "hammer"}}))"""
    let result = run_gene(@["deser", "-e", payload])
    check result.exit_code != 0
    check result.output.contains("Deserialization error")
    check result.output.contains("ExportedThing")
