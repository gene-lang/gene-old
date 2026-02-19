version       = "0.1.0"
author        = "Gene Contributors"
description   = "Gene AI-native VM language in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["gene"]

requires "nim >= 2.0.0"

task build, "Build Gene":
  exec "nim c -o:bin/gene src/gene.nim"

task test, "Run unit tests":
  exec "nim c -r tests/test_parser.nim"
  exec "nim c -r tests/test_compiler.nim"
  exec "nim c -r tests/test_vm.nim"

task suite, "Run Gene test suite":
  exec "nim c -o:bin/gene src/gene.nim"
  for f in listFiles("tests/suite"):
    if f.endsWith(".gene"):
      exec "bin/gene " & f
