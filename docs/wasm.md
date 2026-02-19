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

```bash
GENE_PROFILE=wasm-emscripten \
nim c -d:release \
  --cpu:wasm32 \
  --os:standalone \
  --gc:orc \
  --threads:off \
  --cc:clang \
  --clang.exe:emcc \
  --clang.linkerexe:emcc \
  --passL:"-s WASM=1 -s MODULARIZE=1 -s EXPORT_ES6=1 -s ALLOW_MEMORY_GROWTH=1" \
  src/gene.nim
```

## Cooperative Runtime API

The VM exposes:

- `vm_step(max_instructions)`
- `vm_poll()`
- `vm_resume(task_id, value)`

These APIs are used for host-driven scheduling in WASM environments.
