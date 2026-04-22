import std/unittest
import std/strutils

import ../src/gene_wasm

suite "WASM runtime ABI":
  test "gene_eval captures print output and final result":
    let output = $gene_eval("(println \"hello\") (+ 1 2)")
    check output.contains("hello")
    check output.contains("3")

  test "gene_eval returns textual error on failure":
    let output = $gene_eval("(fn broken [a)")
    check output.contains("error:")

  when defined(gene_wasm):
    test "retired thread-first surface returns an error":
      let output = $gene_eval("(spawn 1)")
      check output.contains("error:")

    test "unsupported process API returns stable wasm code":
      let output = $gene_eval("(system/exec \"echo\" \"hi\")")
      check output.contains("GENE.WASM.UNSUPPORTED")
      check output.contains("process_exec")

    test "unsupported file-backed module import returns stable wasm code":
      let output = $gene_eval("(import value from \"tests/fixtures/mod1\") value")
      check output.contains("GENE.WASM.UNSUPPORTED")
      check output.contains("module_file_loading")
