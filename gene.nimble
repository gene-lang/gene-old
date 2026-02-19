version       = "0.1.0"
author        = "Gene Contributors"
description   = "Gene AI-native VM language in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["gene"]

requires "nim >= 2.0.0"

task build, "Build Gene":
  exec "nim c -o:bin/gene src/gene.nim"
