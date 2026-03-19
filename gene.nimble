# Package

version       = "0.1.0"
author        = "Guoliang Cao"
description   = "Gene - a general purpose language"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
installExt    = @["nim"]
bin           = @["gene"]

# Dependencies
requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0"

task speedy, "Optimized build for maximum performance":
  exec "mkdir -p bin"
  exec "nim c -d:release --mm:orc --opt:speed --passC:\"-march=native -O3\" -o:bin/gene src/gene.nim"

task wasm, "Build Gene WASM runtime module":
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
  exec "nim c --skipUserCfg --skipProjCfg --skipParentCfg -d:gene_wasm -d:gene_wasm_emscripten -d:release -d:emscripten --cpu:wasm32 --os:linux --mm:orc --threads:off --cc:clang --clang.exe:emcc --clang.linkerexe:emcc --passL:'--no-entry -sWASM=1 -sALLOW_MEMORY_GROWTH=1 -sNO_EXIT_RUNTIME=1 -sENVIRONMENT=web -sEXPORTED_FUNCTIONS=[\"_gene_eval\"] -sEXPORTED_RUNTIME_METHODS=[\"cwrap\"]' -o:web/gene_wasm.js src/gene_wasm.nim"

task bench, "Build and run benchmarks":
  exec "nim c -d:release --mm:orc --opt:speed --passC:\"-march=native\" -r bench/run_benchmarks.nim"

task buildext, "Build extension modules":
  exec "mkdir -p build"
  exec "nim c --app:lib -d:release --mm:orc -o:build/libhttp.dylib src/genex/http.nim"
  exec "nim c --app:lib -d:release --mm:orc -o:build/libsqlite.dylib src/genex/sqlite.nim"
  exec "nim c --app:lib -d:release --mm:orc -o:build/libpostgres.dylib src/genex/postgres.nim"
  exec "nim c --app:lib -d:release --mm:orc -o:build/libhtml.dylib src/genex/html.nim"
  exec "nim c --app:lib -d:release --mm:orc -o:build/liblogging.dylib src/genex/logging.nim"
  exec "nim c --app:lib -d:release --mm:orc -o:build/libtest.dylib src/genex/test.nim"
  exec "nim c --app:lib -d:release --mm:orc -o:build/libai.dylib src/genex/ai/bindings.nim"

task buildllmamacpp, "Build LLM runtime dependencies":
  exec "./tools/build_llama_runtime.sh"

task buildwithllm, "Build Gene with LLM support":
  exec "mkdir -p build"
  exec "nim c --app:lib -d:release -d:geneLLM --mm:orc -o:build/libllm.dylib src/genex/llm.nim"
  exec "nim c -d:release -d:geneLLM --mm:orc --opt:speed -o:bin/gene src/gene.nim"

task buildcext, "Build C extension example":
  exec "mkdir -p build/extensions"
  exec "cd tests && make -f Makefile.c_extension"
  exec "cp tests/c_extension.* build/extensions/ 2>/dev/null || true"

task testcore, "Runs the test suite":
  exec "nim c -r tests/test_types.nim"
  exec "nim c -r tests/test_parser.nim"
  exec "nim c -r tests/test_parser_interpolation.nim"

task test, "Runs the test suite":
  exec "nim c -r tests/test_basic.nim"
  exec "nim c -r tests/test_scope.nim"
  exec "nim c -r tests/test_scope_unwind.nim"
  exec "nim c -r tests/test_symbol.nim"
  exec "nim c -r tests/test_repeat.nim"
  exec "nim c -r tests/test_for.nim"
  exec "nim c -r tests/test_case.nim"
  exec "nim c -r tests/test_opcode_dispatch.nim"
  exec "nim c -r tests/test_enum.nim"
  exec "nim c -r tests/test_arithmetic.nim"
  exec "nim c -r tests/test_exception.nim"
  exec "nim c -r tests/test_fp.nim"
  exec "nim c -r tests/test_block.nim"
  exec "nim c -r tests/test_function_optimization.nim"
  exec "nim c -r tests/test_namespace.nim"
  exec "nim c -r tests/test_oop.nim"
  exec "nim c -r tests/test_super.nim"
  exec "nim c -r tests/test_keyword_args.nim"
  exec "nim c -r tests/test_oop.nim"
  # exec "nim c -r tests/test_cast.nim"
  exec "nim c -r tests/test_pattern_matching.nim"
  exec "nim c -r tests/test_macro.nim"
  exec "nim c -r tests/test_async.nim"
  exec "nim c -r tests/test_future_callbacks.nim"
  exec "nim c -r tests/test_pubsub.nim"
  exec "nim c -r tests/test_wasm.nim"
  exec "nim c -r tests/test_module.nim"
  exec "nim c -r tests/test_cli_run.nim"
  exec "nim c -r tests/test_cli_view.nim"
  # exec "nim c -r tests/test_cli_gir.nim"
  # exec "nim c -r tests/test_cli_fmt.nim"
  # exec "nim c -r tests/test_deps_command.nim"
  # exec "nim c -r tests/test_package.nim"
  exec "nim c -r tests/test_selector.nim"
  exec "nim c -r tests/test_template.nim"
  # exec "nim c -r tests/test_serdes.nim"
  exec "nim c -r tests/test_repl.nim"
  exec "nim c -r tests/test_logging.nim"
  exec "nim c -r tests/test_native.nim"
  exec "nim c -r tests/test_native_trampoline.nim"
  # exec "nim c -r tests/test_ai_tools.nim"
  # exec "nim c -r tests/test_ai_runtime_contracts.nim"
  # exec "nim c -r tests/test_ai_slack_control.nim"
  # exec "nim c -r tests/test_ai_agent_runtime.nim"
  # exec "nim c -r tests/test_ai_scheduler.nim"
  # exec "nim c -r tests/test_ai_provider_router.nim"
  # exec "nim c -r tests/test_ai_slack_ingress.nim"
  # exec "nim c -r tests/test_ai_slack_socket_mode.nim"
  # exec "nim c -r tests/test_ai_memory_store.nim"
  # exec "nim c -r tests/test_ai_workspace_policy.nim"
  exec "nim c -r tests/test_ext.nim"
  exec "nim c -r tests/test_custom_value.nim"
  # exec "nim c -d:GENE_LLM_MOCK -r tests/test_llm_mock.nim"
  exec "nim c -r tests/test_thread.nim"
  exec "nim c -r tests/test_thread_msg.nim"
  exec "nim c -r tests/test_viewer_model.nim"
  # exec "nim c -r tests/test_metaprogramming.nim"
  # exec "nim c -r tests/test_array_like.nim"
  # exec "nim c -r tests/test_map_like.nim"
  exec "nim c -r tests/test_stdlib.nim"
  exec "nim c -r tests/test_stdlib_class.nim"
  exec "nim c -r tests/test_stdlib_string.nim"
  exec "nim c -r tests/test_stdlib_array.nim"
  exec "nim c -r tests/test_stdlib_map.nim"
  exec "nim c -r tests/test_stdlib_gene.nim"
  exec "nim c -r tests/test_stdlib_regex.nim"
  exec "nim c -r tests/test_stdlib_json.nim"
  exec "nim c -r tests/test_gdat.nim"
  exec "nim c -r tests/test_stdlib_datetime.nim"
  exec "nim c -r tests/test_stdlib_os.nim"
  exec "nim c -r tests/test_stdlib_process.nim"
  exec "nim c -r tests/test_stdlib_stdio.nim"
  exec "nim c -r tests/test_stdlib_sqlite.nim"
  exec "nim c -r tests/test_geneclaw_cli_mode.nim"
  # exec "nim c -d:postgresTest tests/test_stdlib_postgres.nim"
  # exec "DYLD_LIBRARY_PATH=/opt/homebrew/opt/postgresql@16/lib:$DYLD_LIBRARY_PATH tests/test_stdlib_postgres"
  # exec "nim c -r tests/test_ffi.nim"

task testpostgres, "Runs postgres tests":
  exec "nim c -d:postgresTest tests/test_stdlib_postgres.nim"
  exec "DYLD_LIBRARY_PATH=/opt/homebrew/opt/postgresql@16/lib:$DYLD_LIBRARY_PATH tests/test_stdlib_postgres"
