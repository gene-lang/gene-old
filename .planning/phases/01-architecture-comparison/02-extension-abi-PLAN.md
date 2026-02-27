---
phase: 01-architecture-comparison
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - src/gene/vm/extension_abi.nim
  - src/gene/vm/extension.nim
  - src/gene/vm.nim
  - src/genex/sqlite.nim
  - src/genex/http.nim
  - tests/test_ext.nim
autonomous: true
requirements:
  - EXT-01

must_haves:
  truths:
    - "gene-old no longer statically imports genex modules at the top of vm.nim"
    - "A stable C-ABI struct (GeneHostApi) is defined for extension registration"
    - "The existing extension loader in vm/extension.nim is upgraded to use the new ABI"
    - "At least sqlite and http can be built as shared libraries via nimble buildext and loaded at runtime"
    - "test_ext.nim tests pass using the dynamic load path"
  artifacts:
    - path: "src/gene/vm/extension_abi.nim"
      provides: "GeneExtAbiVersion, GeneNativeFn, GeneHostApi, GeneExtensionInitFn type definitions"
      exports: ["GeneExtAbiVersion", "GeneNativeFn", "GeneHostApi", "GeneExtensionInitFn"]
    - path: "src/gene/vm/extension.nim"
      provides: "Updated load_extension using GeneHostApi with ABI version check"
      contains: "GeneExtAbiVersion"
    - path: "src/gene/vm.nim"
      provides: "Static genex imports removed; runtime loading used instead"
      contains: "no longer: import ../genex/http"
  key_links:
    - from: "src/gene/vm/extension.nim"
      to: "src/gene/vm/extension_abi.nim"
      via: "load_extension uses GeneHostApi and GeneExtensionInitFn"
      pattern: "GeneHostApi"
    - from: "src/genex/sqlite.nim"
      to: "src/gene/vm/extension_abi.nim"
      via: "sqlite.nim exports gene_init(host: ptr GeneHostApi) instead of init(vm)"
      pattern: "gene_init"
---

<objective>
Define a stable C-ABI extension contract for gene-old, replace the static genex imports in vm.nim with runtime dynamic loading, and migrate at least the sqlite and http extensions to the new ABI.

Purpose: Directly fixes the top tech debt item from CONCERNS.md ("VM statically imports multiple genex modules as a temporary workaround"). After this plan, extensions are independent shared libraries loaded at runtime without recompiling gene-old. This enables third-party extensions and modular deployment.

Output: New extension_abi.nim type contract; upgraded extension.nim loader with ABI version checking; sqlite.nim and http.nim adapted to export gene_init; static imports removed from vm.nim.
</objective>

<execution_context>
@/Users/gcao/.claude/get-shit-done/workflows/execute-plan.md
@/Users/gcao/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@/Users/gcao/gene-workspace/gene-old/.planning/codebase/ARCHITECTURE.md
@/Users/gcao/gene-workspace/gene-old/.planning/codebase/CONCERNS.md

<interfaces>
<!-- Key types and contracts the executor needs. Extracted from codebase. -->

Current extension.nim types (to be superseded):
```nim
type
  Init* = proc(vm: ptr VirtualMachine): Namespace {.gcsafe, nimcall.}
  SetGlobals* = proc(vm: ptr VirtualMachine) {.nimcall.}
```

Current extension.nim load_extension flow:
1. dlopen the library
2. Lookup "set_globals" symbol -> call set_globals(vm)
3. Lookup "init" symbol -> call init(vm) -> returns Namespace

Current vm.nim static imports (lines ~85-94):
```nim
# Temporarily import http and sqlite modules until extension loading is fixed
when not defined(GENE_NO_STDLIB):
  import "../genex/http"
  import "../genex/sqlite"
  import "../genex/html"
  import "../genex/logging"
  import "../genex/test"
  import "../genex/ai/bindings"
when defined(GENE_LLM):
  import "../genex/llm"
```

Reference ABI from gene/src/native_abi.nim:
```nim
const GeneAbiVersion* = 1'u32

type
  GeneHostApi* {.bycopy.} = object
    abi_version*: uint32
    user_data*: pointer
    register_native*: GeneRegisterNativeFn   # proc(reg, userData): int32 {.cdecl.}

  GeneExtensionInitFn* = proc(host: ptr GeneHostApi): int32 {.cdecl.}
```

gene-old's NativeFn type (already defined in type_defs.nim - new ABI must be compatible):
```nim
NativeFn* = proc(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.}
```

Note: gene-old's NativeFn uses Nim calling convention (nimcall). The new GeneExtensionInitFn must use {.cdecl.} for C ABI stability. However, registered native functions can still use the existing nimcall NativeFn type internally, bridged through a cdecl wrapper in the host API callback.

nimble.buildext task (already exists):
```
nim c --app:lib -d:release --mm:orc -o:build/libhttp.dylib src/genex/http.nim
nim c --app:lib -d:release --mm:orc -o:build/libsqlite.dylib src/genex/sqlite.nim
```
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Define GeneHostApi ABI contract in extension_abi.nim</name>
  <files>src/gene/vm/extension_abi.nim</files>
  <action>
Create `src/gene/vm/extension_abi.nim` that defines the stable C-ABI contract for gene-old extensions.

This file will be `include`d in the vm.nim include chain AND also imported by genex modules (so it must compile standalone as an importable module, not just via include). Make it a proper `import`-able module: use `import ../gene/types` for the Value and VirtualMachine types needed.

Define the following:

```nim
## extension_abi.nim - Stable C ABI for gene-old native extensions
##
## Extension shared libraries must export a single entry point:
##   proc gene_init(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.}
##
## The host calls gene_init once after loading. The extension calls
## host.register_fn to register each native function.
##
## ABI version: Increment GENE_EXT_ABI_VERSION when the GeneHostAbi struct changes.

const GENE_EXT_ABI_VERSION* = 1'u32

type
  ## Status codes returned by ABI functions
  GeneExtStatus* = enum
    GeneExtOk = 0
    GeneExtErr = 1

  ## C-compatible native function signature.
  ## Extensions use this to expose functions to Gene programs.
  ## vm_ptr: opaque pointer to VirtualMachine (cast as needed by host)
  ## args: pointer to argument array
  ## arg_count: number of arguments
  ## has_kw: 1 if keyword args present, 0 otherwise
  ## Returns: opaque Value encoded as uint64 (use host's decode helpers)
  GeneExtNativeFn* = proc(
    vm_ptr: pointer;
    args: pointer;
    arg_count: int32;
    has_kw: int32
  ): uint64 {.cdecl.}

  ## Registration record passed to host.register_fn
  GeneExtFnReg* {.bycopy.} = object
    name*: cstring          ## Function name as seen from Gene namespace
    fn*: GeneExtNativeFn    ## The native function pointer
    arity*: int16           ## Expected arity (-1 = variadic)

  ## Callback type: host provides this so extensions can register functions
  GeneRegisterFnCallback* = proc(
    reg: ptr GeneExtFnReg;
    user_data: pointer
  ): int32 {.cdecl.}

  ## Host API struct passed to gene_init. Extensions must check abi_version
  ## before using any fields. Struct is {.bycopy.} for C ABI stability.
  GeneHostAbi* {.bycopy.} = object
    abi_version*: uint32          ## Must equal GENE_EXT_ABI_VERSION
    user_data*: pointer           ## Opaque host context (ptr VirtualMachine)
    register_fn*: GeneRegisterFnCallback  ## Register a native function

  ## Entry point that extensions must export
  GeneExtensionInitFn* = proc(host: ptr GeneHostAbi): int32 {.cdecl.}
```

This file must compile cleanly on its own:
```bash
nim c --mm:orc src/gene/vm/extension_abi.nim
```
  </action>
  <verify>nim c --mm:orc src/gene/vm/extension_abi.nim 2>&1 | head -20</verify>
  <done>extension_abi.nim compiles without errors; exports GENE_EXT_ABI_VERSION, GeneHostAbi, GeneExtFnReg, GeneExtensionInitFn.</done>
</task>

<task type="auto">
  <name>Task 2: Upgrade extension.nim loader and remove static vm.nim imports</name>
  <files>
    src/gene/vm/extension.nim
    src/gene/vm.nim
    src/genex/sqlite.nim
    src/genex/http.nim
    tests/test_ext.nim
  </files>
  <action>
**Step 1: Update src/gene/vm/extension.nim to use GeneHostAbi.**

The existing `load_extension` proc uses the old `Init`/`SetGlobals` approach. Upgrade it to use the new ABI:

1. Add `include ./extension_abi` at the top (after existing imports).

2. Rewrite `load_extension` to:
   - dlopen as before
   - Look up `"gene_init"` symbol (the new entry point) using `symAddr`
   - If not found, fall back to old `"init"` symbol for backward compatibility with existing .dylib files
   - If using new path: build a `GeneHostAbi` struct with:
     - `abi_version = GENE_EXT_ABI_VERSION`
     - `user_data = vm` (cast to pointer)
     - `register_fn` = a closure that wraps the NativeFn registration
   - The `register_fn` callback: receives `GeneExtFnReg`, creates a `Value` of kind `VkNativeFn`, registers it in the returned namespace
   - The challenge: `register_fn` is a `{.cdecl.}` proc so it cannot close over Nim variables directly. Use `user_data` to pass a pointer to a temporary registration context struct.
   - Call `gene_init(addr host_abi)`, check return code
   - If `gene_init` returns `GeneExtOk` (0), return the built namespace
   - If using old path: call `set_globals(vm)` then `init(vm)` as before

3. The registration context approach:
```nim
type
  RegCtx = object
    vm: ptr VirtualMachine
    ns: Namespace

proc register_fn_callback(reg: ptr GeneExtFnReg; user_data: pointer): int32 {.cdecl.} =
  let ctx = cast[ptr RegCtx](user_data)
  # Convert GeneExtNativeFn to NativeFn via cdecl-to-nimcall adapter
  # Register the function in ctx.ns under reg.name
  ...
  return 0
```

Note: The cdecl-to-nimcall bridge is the trickiest part. The simplest approach is to store the GeneExtNativeFn pointer in a Value and call it via a nimcall wrapper proc that does the cast. See how existing NativeFn is stored: `r.native_fn = the_fn` where `r` is `new_ref(VkNativeFn)`.

**Step 2: Remove static imports from src/gene/vm.nim.**

Find the block (around line 85-94):
```nim
# Temporarily import http and sqlite modules until extension loading is fixed
when not defined(GENE_NO_STDLIB):
  import "../genex/http"
  ...
```

Replace it with a comment:
```nim
# Extensions are now loaded at runtime via src/gene/vm/extension.nim
# Use: (import genex/sqlite) or (import genex/http) in Gene programs
# Extensions must be pre-built: nimble buildext
```

Also update the vm_modules.nim or wherever stdlib registration happens: the genex namespaces that were previously pre-registered via static imports now need to be loaded on demand. Check `src/gene/vm/vm_modules.nim` to see how the genex namespaces were registered and whether removing the imports breaks anything.

**Step 3: Minimal adaptation of src/genex/sqlite.nim and src/genex/http.nim.**

Add a new exported entry point to each extension. These files still compile as standalone libraries via `nimble buildext`. Add at the bottom of each file:

```nim
# New stable ABI entry point
import ./gene/vm/extension_abi  # adjust path based on compile context

proc gene_init*(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.} =
  if host.abi_version != GENE_EXT_ABI_VERSION:
    return 1  # ABI version mismatch
  # Use existing init(vm) logic, adapting to the registration callback approach
  # OR: call the old init proc and register its namespace contents via register_fn
  return 0
```

The path for importing extension_abi from genex/ may need adjustment. Since genex files are compiled standalone with `nim c --app:lib`, the import path must be relative to the genex file. Check the existing import paths in sqlite.nim to determine the correct relative path (likely `../gene/vm/extension_abi`).

If adapting the full gene_init is too complex in this plan, a minimal viable approach is:
- Export `gene_init` that calls the old `init(vm)` after extracting `vm` from `host.user_data`
- This preserves existing functionality while exposing the new entry point

**Step 4: Update tests/test_ext.nim.**

Verify that the existing test_ext.nim tests still pass. If any tests relied on the static import path, update them to use the dynamic load path. Check what test_ext.nim currently tests and add a comment noting which tests exercise the new ABI.

Run: `nim c -r tests/test_ext.nim`
  </action>
  <verify>nim c -r tests/test_ext.nim 2>&1 | tail -20</verify>
  <done>
    - vm.nim no longer has the static genex import block (search: grep "Temporarily import" src/gene/vm.nim should return empty)
    - extension.nim has a gene_init lookup path and GeneHostAbi struct
    - sqlite.nim and http.nim export gene_init
    - test_ext.nim passes
    - nimble buildext succeeds and produces .dylib files
  </done>
</task>

</tasks>

<verification>
Run from /Users/gcao/gene-workspace/gene-old:
1. `grep -n "Temporarily import" src/gene/vm.nim` - should return empty (imports removed)
2. `nim c -r tests/test_ext.nim` - extension tests pass
3. `nim c -r tests/test_native.nim` - native function tests unaffected
4. `nimble buildext` - builds libsqlite.dylib, libhttp.dylib successfully
5. `nim c -r tests/test_basic.nim` - no regressions in core VM
</verification>

<success_criteria>
- vm.nim has no static genex imports (the "Temporarily import" comment block is gone)
- extension_abi.nim defines GENE_EXT_ABI_VERSION and GeneHostAbi
- load_extension in extension.nim supports gene_init entry point with ABI version check
- sqlite.nim and http.nim export gene_init satisfying the new ABI
- All test_ext.nim tests pass
- nimble buildext produces .dylib files
</success_criteria>

<output>
After completion, create `/Users/gcao/gene-workspace/gene-old/.planning/phases/01-architecture-comparison/01-02-SUMMARY.md`
</output>
