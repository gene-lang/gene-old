version       = "0.1.0"
author        = "Gene Contributors"
description   = "Gene AI-native VM language in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["gene"]

requires "nim >= 2.0.0"

task build, "Build Gene":
  exec "nim c -o:bin/gene src/gene.nim"

task wasm, "Build Gene WASM playground module":
  mkDir("web")
  if findExe("emcc").len == 0:
    echo "emcc was not found on PATH."
    echo "Install Emscripten (emsdk) and activate it:"
    echo "  git clone https://github.com/emscripten-core/emsdk.git"
    echo "  cd emsdk"
    echo "  ./emsdk install latest"
    echo "  ./emsdk activate latest"
    echo "  source ./emsdk_env.sh"
    quit("emcc is required for `nimble wasm`.", QuitFailure)
  exec "GENE_PROFILE=wasm-emscripten nim c -d:release -d:emscripten --cpu:wasm32 --os:linux --mm:orc --threads:off --cc:clang --clang.exe:emcc --clang.linkerexe:emcc --passL:'--no-entry -sWASM=1 -sALLOW_MEMORY_GROWTH=1 -sNO_EXIT_RUNTIME=1 -sENVIRONMENT=web -sEXPORTED_FUNCTIONS=[\"_gene_eval\"] -sEXPORTED_RUNTIME_METHODS=[\"cwrap\"]' -o:web/gene_wasm.js src/gene_wasm.nim"

task test, "Run unit tests":
  exec "nim c -r tests/test_parser.nim"
  exec "nim c -r tests/test_compiler.nim"
  exec "nim c -r tests/test_vm.nim"

task suite, "Run Gene test suite":
  exec "nim c -o:bin/gene src/gene.nim"
  for f in listFiles("tests/suite"):
    if f.endsWith(".gene"):
      exec "bin/gene " & f

task bench, "Run call benchmarks (release)":
  exec "nim c -d:release -o:bin/bench_calls benchmarks/bench_calls.nim"
  exec "bin/bench_calls"

task benchd, "Run call benchmarks (debug)":
  exec "nim c -o:bin/bench_calls benchmarks/bench_calls.nim"
  exec "bin/bench_calls"
