# Task: Split value_core.nim into modules

`src/gene/types/value_core.nim` is 2,525 lines. It has clear section markers (`##########`) that map to natural modules. Split it into `src/gene/types/` subfiles.

## Current Sections (by line markers)

```
  11  NaN Boxing implementation
  49  Forward declarations
  74  Runtime globals
 112  Common (Key, Id, todo, not_allowed)
 147  Reference (retain, release, array_ptr, map_ptr, instance_ptr, new_ref)
 317  Symbol (symbol table, to_symbol_value, to_key)
 367  Value (==, kind, is_literal, $, str_no_quotes)
 909  Int constructors
 954  String constructors
1017  ComplexSymbol
1024  Array constructors
1057  Stream
1064  Set
1070  Map constructors
1088  Instance
1108  Range
1184  SourceTrace
1210  Gene (Gene constructors, to_value)
1258  Application
1273  Namespace (Namespace ops, def, def_member, has_key)
1378  Scope (new_scope, scope operations)
1462  ScopeTracker (scope tracker ops, copy, snapshot, materialize)
1545  Pattern Matching (Matcher, RootMatcher, parse)
1936  Function (to_function, new_fn)
2100  Block (to_block, new_block)
2140  Future (FutureObj operations)
2227  Enum
2266  Native (get_positional_arg, call_native_fn, etc.)
2345  Frame (frame operations, stack push/pop)
```

## Target Structure

Group related sections into focused files:

```
src/gene/types/
  value_core.nim        — Hub: imports and re-exports (or includes) all sub-files
  nan_boxing.nim        — NaN boxing implementation, forward declarations, runtime globals (~100 lines)
  value_ops.nim         — Common (Key/Id), Value (==, kind, $, str_no_quotes, is_literal), retain/release (~560 lines)
  symbols.nim           — Symbol table, to_symbol_value, to_key (~50 lines)
  constructors.nim      — Int, String, ComplexSymbol, Array, Stream, Set, Map, Instance, Range, Gene, SourceTrace constructors (~530 lines)
  collections.nim       — Application, Namespace operations, Scope operations, ScopeTracker (~365 lines)
  matchers.nim          — Pattern Matching: Matcher, RootMatcher, parse, type resolution (intern_type_desc, resolve_type_value_to_id) (~390 lines)
  functions.nim         — Function (to_function, new_fn), Block (to_block, new_block) (~240 lines)
  futures.nim           — FutureObj operations, Enum (~130 lines)
  native_helpers.nim    — Native fn arg helpers (get_positional_arg, get_keyword_arg, call_native_fn) (~80 lines)
  frames.nim            — Frame operations (new_frame, push, pop, CallBaseStack) (~190 lines)
```

## Rules

1. **Keep `value_core.nim` as the public interface** — `include` subfiles (not `import`) because many procs reference types and globals from each other. The existing pattern in the codebase uses `include` for tightly-coupled splits.
2. **No behavior changes** — pure refactoring
3. **All tests must pass**: `nim c -d:release -o:bin/gene src/gene.nim && nimble test && ./testsuite/run_tests.sh`
4. **Start with the most self-contained sections:**
   - `frames.nim` (Frame ops, at the bottom, self-contained)
   - `native_helpers.nim` (small, self-contained)
   - `futures.nim` (FutureObj + Enum)
   - Then work upward
5. **Build and test after each extraction**

## Build & Test

```bash
nim c -d:release -o:bin/gene src/gene.nim
nimble test
./testsuite/run_tests.sh
```
