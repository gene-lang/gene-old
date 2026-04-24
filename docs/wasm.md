# WASM Runtime (Emscripten)

Gene supports a WebAssembly runtime target focused on host-embedded evaluation.

## Build

Prerequisites:
- Nim toolchain
- Emscripten (`emcc`) on `PATH`

Build artifacts:

```bash
nimble wasm
```

This produces:
- `web/gene_wasm.js`
- `web/gene_wasm.wasm`

The wasm task compiles with `--skipUserCfg --skipProjCfg --skipParentCfg` so host-specific native flags (for example `-march=native`) do not leak into the Emscripten build.

## Runtime Profile

Use `GENE_PROFILE=wasm-emscripten` to enable wasm compile-time guards:
- `-d:gene_wasm`
- `-d:gene_wasm_emscripten`
- `--threads:off`

## Exported ABI

WASM exposes:
- `gene_eval(code: cstring): cstring`

`gene_eval` parses, compiles, and executes the passed Gene source, then returns textual output/result. Failures are returned as error text (no runtime crash).

## Host ABI Contract

In wasm mode, effectful runtime operations route through host ABI wrappers:
- `gene_host_now`
- `gene_host_rand`
- `gene_host_file_exists`
- `gene_host_read_file`
- `gene_host_write_file`
- `gene_host_free`

## Unsupported Features in WASM

These operations fail deterministically with `GENE.WASM.UNSUPPORTED`:
- Actor-first public concurrency surface backed by native workers (`actors`)
- Dynamic native extension loading (`dynamic_extension_loading`)
- Process/shell execution (`process_exec`, `process_shell`)
- File-backed module loading (`module_file_loading`)
- Directory and delete filesystem operations (`directory_ops`, `file_delete`)

Example error format:

```text
[GENE.WASM.UNSUPPORTED] <feature> is not available in wasm
```
