# Native Extension Example

This folder contains a minimal C extension for Gene's C ABI.

## Build (macOS)

```bash
cc -shared -fPIC \
  -I./include \
  -o examples/extensions/simple_ext.dylib \
  examples/extensions/simple_ext.c
```

## Build (Linux)

```bash
cc -shared -fPIC \
  -I./include \
  -o examples/extensions/simple_ext.so \
  examples/extensions/simple_ext.c
```

## Run

```gene
(cap_grant "cap.ffi.call")
(native/load "./examples/extensions/simple_ext.dylib")
(ext_id 42)
```

The extension exports `gene_extension_init` and registers one native:

- `ext_id` with arity `1`
