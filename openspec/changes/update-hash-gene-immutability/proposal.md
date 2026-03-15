## Why

The value-vs-entity proposal reserves `#(...)` for immutable gene values, but the parser does not recognize that syntax today. Gene values remain structurally mutable, and top-level `#(` currently falls back to a meaningless `#` token followed by a normal gene form.

## What Changes

- Add `#(...)` as immutable gene literal syntax, compiling as a literal value rather than an executable call form.
- Add immutable-gene runtime semantics so prop, child, and genetype mutations fail clearly instead of mutating in place.
- Add a `Gene.immutable?` predicate so code can inspect frozen state.
- Preserve immutable genes through compiler, VM, GIR, serdes, and textual rendering paths.
- Keep existing `#"` string interpolation semantics unchanged.

## Impact

- Affected specs: `hash-literals`
- Affected code: `src/gene/parser.nim`, gene constructors/types, VM assignment paths, stdlib gene APIs, GIR/serdes, parser/runtime tests
