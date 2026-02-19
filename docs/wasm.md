# WASM Build Profiles

Gene supports three build profiles via `GENE_PROFILE`:

- `native` (default)
- `wasm-wasi`
- `wasm-emscripten`

`config.nims` sets compile-time defines from `GENE_PROFILE`:

- `gene_native`
- `gene_wasm` + `gene_wasm_wasi`
- `gene_wasm` + `gene_wasm_emscripten`

In WASM profiles:

- OS threads are disabled.
- Dynamic native extension loading (`native/load`) is disabled.
- File and clock/random effects are routed through `src/wasm_host_abi.nim`.

## Native (default)

```bash
nim c -d:release -o:bin/gene src/gene.nim
```

## WASI

```bash
GENE_PROFILE=wasm-wasi \
nim c -d:release \
  --cpu:wasm32 \
  --os:standalone \
  --gc:orc \
  --threads:off \
  --cc:clang \
  --clang.exe:clang \
  --clang.linkerexe:wasm-ld \
  --passC:"--target=wasm32-wasi --sysroot=$WASI_SYSROOT" \
  --passL:"--target=wasm32-wasi --sysroot=$WASI_SYSROOT" \
  src/gene.nim
```

## Emscripten

Install Emscripten (`emcc`) with `emsdk`:

```bash
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh
```

Then build the browser playground module:

```bash
nimble wasm
```

This emits:

- `web/gene_wasm.js`
- `web/gene_wasm.wasm`

Manual equivalent:

```bash
GENE_PROFILE=wasm-emscripten \
nim c -d:release \
  -d:emscripten \
  --cpu:wasm32 \
  --os:linux \
  --mm:orc \
  --threads:off \
  --cc:clang \
  --clang.exe:emcc \
  --clang.linkerexe:emcc \
  --passL:"--no-entry -sWASM=1 -sALLOW_MEMORY_GROWTH=1 -sNO_EXIT_RUNTIME=1 -sENVIRONMENT=web -sEXPORTED_FUNCTIONS=[\"_gene_eval\"] -sEXPORTED_RUNTIME_METHODS=[\"cwrap\"]" \
  -o:web/gene_wasm.js \
  src/gene_wasm.nim
```

`src/gene_wasm.nim` exports:

- `gene_eval(code: cstring): cstring`

It parses, compiles, and runs Gene source, returning captured `print/println` output plus the final expression value as a string.
In WASM profiles, OS threads are disabled and `native/load` dynamic extension loading is disabled.

To run the UI:

```bash
python3 -m http.server 8080
# open http://localhost:8080/web/
```

## Cooperative Runtime API

The VM exposes:

- `vm_step(max_instructions)`
- `vm_poll()`
- `vm_resume(task_id, value)`

These APIs are used for host-driven scheduling in WASM environments.
