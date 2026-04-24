# Gene IR (`.gir`) — Compile & Run

This document introduces a fast-start workflow for Gene by compiling source to a **Gene IR** file (`.gir`) and running it directly in the VM.

> TL;DR  
> - `gene compile x.gene` → writes `build/x.gir`  
> - `gene run x.gir` → runs precompiled IR directly (no parse/compile on startup)  
> - `gene run x.gene` → runs source; optionally uses a matching up‑to‑date `build/x.gir` cache

---

## Why `.gir`?

Compiling once and running many times reduces startup latency by skipping:
- Tokenization & parsing
- AST construction
- Compile-time symbol interning & constant folding

On typical scripts this yields 2–5× faster cold start (and often more on large programs).

---

## Commands

### `gene compile`
Compile a Gene source file (or files) to **GIR**.

```bash
gene compile x.gene
# => build/x.gir
```

**Behaviour**
- Output directory defaults to `build/`. The relative layout of the input file is preserved.
- The compiler emits a versioned, relocatable GIR with a constant pool, symbol table, and metadata section.
- When `--emit-debug` is set, line/column information is embedded to improve stack traces.

**Options**
```
-h, --help               Show usage information
-e, --eval <code>        Compile inline Gene code instead of reading a file
-f, --format <mode>      Presentation: pretty (default), compact, bytecode, gir
-o, --out-dir <dir>      Override output directory (default: build/)
-a, --addresses          Show instruction addresses in pretty output
--force                  Rebuild even if the cached GIR is newer
--emit-debug             Include debug info in emitted GIR files
```

**Examples**
```bash
# Single file
gene compile src/app/main.gene            # build/src/app/main.gir

# Many files (shell globbing)
gene compile src/**/*.gene                # build/src/**.gir

# Custom output directory
gene compile -o out src/app/main.gene     # out/src/app/main.gir
```

---

### `gene run`
Run either **source** or **precompiled** Gene IR.

```bash
# Run a GIR directly (fastest path)
gene run build/x.gir

# Run from source (will parse/compile)
gene run x.gene
```

**Smart cache behaviour**
- `gene run foo.gene` will look for `build/foo.gir`. If the GIR is newer than the source (and compatible), the VM loads it directly.
- Pass `--no-gir-cache` to force recompilation from source.

**Options**
```
-d, --debug                 Enable verbose logging
--repl-on-error             Enter REPL if an exception escapes the program
--trace                     Enable VM instruction tracing
--trace-instruction         Compile, print instructions, and trace execution
--compile                   Parse & compile only; output instructions (no exec)
--profile                   Print per-function execution stats after run
--profile-instructions      Print per-opcode execution counts after run
--no-gir-cache              Ignore cached GIR artifacts
```
The executed script path is exposed as `$program`, and additional positional arguments after the file are stored in `$args`.

**Examples**
```bash
gene run build/x.gir
gene run script.gene arg1 arg2
gene run --no-gir-cache script.gene
```

---

## File layout

```
myproj/
  src/
    x.gene
  build/
    x.gir           # produced by `gene compile src/x.gene`
```

With nested sources, the relative layout under `build/` mirrors `src/`:

```
src/app/main.gene  ->  build/src/app/main.gir
```

Use `-o out/` to customize:

```
gene compile -o out src/app/main.gene  ->  out/src/app/main.gir
```

---

## GIR validity & cache rules

A `.gir` is considered **valid** when:
- `GIR_VERSION` matches the VM's supported format version
- `COMPILER_VERSION` matches the compiler that produced the artifact
- `VALUE_ABI_VERSION` is present in the VM ABI marker
- `INSTRUCTION_ABI_VERSION` is present in the VM ABI marker
- The embedded **source hash** still matches the current source file

If any check fails, the loader will refuse the artifact and (when invoked via `gene run x.gene`) fall back to recompilation.
Direct `gene run x.gir` loads fail with diagnostics that include the path,
expected value, actual value, and recompile guidance.

**Flags embedded in `.gir`:**
- `GIR_VERSION` — bump on incompatible IR format changes
- `COMPILER_VERSION` — compiler semantic version/fingerprint
- `vm_abi` — Nim version, word size, `VALUE_ABI_VERSION`, and `INSTRUCTION_ABI_VERSION`
- `debug` — whether line/col maps are present
- `published` — reserved release-artifact marker
- `source hash` — hash of the source text used by cache validation

The source runner checks headers before using a cached `.gir`. Stale compiler
versions, Value ABI mismatches, instruction ABI mismatches, bad magic, bad GIR
versions, and source hash mismatches all invalidate the cache and trigger a
source recompile.

---

## Safety & portability

- Never store raw host pointers in `.gir`. Use indices into a constant pool. The loader rebuilds boxed `Value`s.
- All integers/floats are serialized with a stable, little‑endian on-disk format (floats as IEEE‑754 bits; canonicalize NaNs).
- Imports (native functions, classes) are recorded by **symbolic name** and resolved at load‑time; signature mismatches cause a load error.
- Optional signing: you may require a valid signature to run external `.gir` files.

---

## Makefile / Script examples

```makefile
# Makefile
BUILD_DIR := build

SOURCES := $(shell find src -name '*.gene')
ARTIFACTS := $(patsubst %.gene,$(BUILD_DIR)/%.gir,$(SOURCES))

$(BUILD_DIR)/%.gir: %.gene
	@mkdir -p $(dir $@)
	gene compile -o $(BUILD_DIR) $<

build: $(ARTIFACTS)

run: $(BUILD_DIR)/src/app/main.gir
	gene run $<
```

```bash
# Simple build script
set -euo pipefail
for f in $(find src -name '*.gene'); do
  gene compile "$f" -o build
done
gene run build/src/app/main.gir
```

---

## Programmatic API (optional)

```nim
# Pseudocode / sketch
let cu = loadGIR("build/x.gir")       # fast load path
vm.run(cu, args=@["--flag1","value"]) # execute
```

---

## FAQ

**Q: Can I ship `.gir` without source?**  
A: Yes. Mark artifacts as `published` (or ship without source hashes). Imports are relinked on the target host. Include debug info if you want readable stack traces.

**Q: What happens if I change macros or natives?**  
A: If their names or ABI signatures change, the loader will refuse old GIR files. Behaviour-only changes require bumping the dependency hash so cached artifacts can be invalidated.

**Q: Is `.gir` stable forever?**  
A: It’s stable **per IR version**. When the format changes incompatibly we bump the version and the loader asks you to recompile.

- **New**: `gene compile <files...>` → writes `.gir` under `build/` (default) or `--out-dir`.
- **Updated**: `gene run` accepts both `*.gene` and `*.gir`.  
  When given `*.gene`, it **may** auto‑use a valid `build/*.gir` cache unless `--no-gir-cache` is set.

---

Happy fast‑starts! 🚀
