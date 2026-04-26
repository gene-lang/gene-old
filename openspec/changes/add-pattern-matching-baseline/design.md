## Context
We are finalizing the minimal pattern-matching story around behavior that exists today: argument binding, `var` destructuring, simple `case/when`, and enum ADT `case` patterns. The standalone `(match ...)` expression is removed in the current compiler, so this baseline records the replacement boundary instead of assigning new implementation work to the removed form.

## Goals / Non-Goals
- Goals: document minimal semantics, preserve performance for argument matching (no aggregate object), define scope/shadowing rules, and pin diagnostics for invalid Beta-subset patterns.
- Non-Goals: reintroduce `(match ...)`, add full pattern language support (maps, nested patterns, guards, or-patterns, as-patterns, view patterns), or introduce pointer-based matcher/IkMatch optimization now.

## Decisions
- Scope: argument binding and `var` destructuring reuse the current binding context according to the existing matcher path; shadowing remains allowed where the current binder allows it.
- Input shape: argument matching continues to consume stack arguments without aggregating them into a temporary collection.
- Removed expression boundary: `(match ...)` is not part of the Beta subset. Users should bind with `(var pattern value)` or branch with `(case ...)`.
- Diagnostics: invalid arity, type, unsupported pattern forms, and removed legacy syntax should produce targeted diagnostics rather than low-level VM or matcher failures.
- Performance: argument matching must not allocate an aggregate argument object.

## Resolved Questions
- Arity contract: arity mismatch is an error for supported destructuring forms.
- Type contract: type mismatch is an error for supported destructuring forms.
- Pattern forms: the Beta subset is limited to tested destructuring, simple `case/when`, and enum ADT `case` patterns. Rest binding follows `update-rest-binding-semantics`; guards, or-patterns, as-patterns, map destructuring, nested patterns, and a standalone match expression remain Future/Removed.
- Error model: diagnostics should be meaningful and user-facing for invalid Beta-subset use.
