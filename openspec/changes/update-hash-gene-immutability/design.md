## Context

Genes are composite runtime values with a type, props, and children. They are used both as syntax nodes and as normal runtime values. Today `#(` is only recognized inside `#"` string interpolation parsing; at the top level, `#(` is not a dispatch form and does not produce a meaningful value.

The compiler already has a literal-gene construction path for `(_ ...)`, which produces a gene value instead of treating the form as an executable call. `#(...)` should behave like that literal path, but with immutable semantics.

Genes already expose mutating APIs through direct assignment paths and stdlib helpers such as `Gene.set`, `Gene.del`, `Gene.set_child`, `Gene.add_child`, `Gene.ins_child`, `Gene.del_child`, and `Gene.set_genetype`. `Gene.props` and `Gene.children`, however, already return fresh containers rather than live aliases of the underlying storage.

## Goals / Non-Goals

- Goals:
  - Make `#(...)` produce an immutable gene value.
  - Reject runtime mutations against immutable genes with explicit errors.
  - Expose `Gene.immutable?` for frozen-state inspection.
  - Preserve immutable genes through display and roundtrip paths.
  - Leave `#"` string interpolation behavior unchanged.
- Non-Goals:
  - Deep-freeze nested child or prop values recursively.
  - Redesign string interpolation syntax.
  - Change mutable `( ... )` gene semantics outside the new hash form.

## Decisions

- Decision: represent immutable genes as normal `Gene` objects with an explicit `frozen` flag.
- Alternatives considered: add a separate `ValueKind` for frozen genes. Rejected because it would widen the change across compilation, VM dispatch, serialization, and display with little benefit.

- Decision: compile `#(...)` through the existing literal-gene construction path, analogous to `(_ ...)`, instead of normal executable gene compilation.
- Alternatives considered: parse `#(...)` into an ordinary `VkGene` and infer literal semantics later. Rejected because executable gene compilation is the current default for bare gene forms and would make the semantics brittle.

- Decision: enforce immutability at explicit gene mutation boundaries, including VM assignment to gene props/children and stdlib gene mutation methods.
- Alternatives considered: copy-on-write mutation. Rejected because the proposal is for immutable value semantics, not implicit cloning through mutable APIs.

- Decision: keep `Gene.props` and `Gene.children` returning fresh containers rather than exposing live aliased storage.
- Alternatives considered: return frozen map/array views. Rejected for this change because the current copy behavior already avoids alias-based mutation of the underlying gene.

- Decision: treat `#(` under `#"` interpolation as unchanged because interpolation parsing is contextual and separate from top-level `#` dispatch.
- Alternatives considered: redesign interpolation while adding `#(...)`. Rejected because there is no direct syntax conflict in the parser today.

## Risks / Trade-offs

- Mutation coverage must be audited carefully; missing one write path would undermine immutable-gene semantics.
- Compiler or serdes code that rebuilds genes must preserve the frozen flag explicitly.
- Shallow immutability means nested mutable values can still be mutated through their own APIs, which is consistent with current frozen array/map behavior but worth documenting.

## Migration Plan

1. Add immutable-gene syntax and runtime guards.
2. Preserve the frozen flag through compiler, VM, GIR, and serdes rebuild paths.
3. Update docs/tests to treat `#(...)` as immutable genes.
4. Keep string interpolation coverage in place to prevent regressions.
