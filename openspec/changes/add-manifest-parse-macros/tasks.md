## 1. Requirements & Scope
- [ ] 1.1 Confirm parse-macro-enabled scope starts with `package.gene` and does not change normal module/runtime evaluation semantics.
- [ ] 1.2 Confirm parse-macro output contract for manifest readers (resolved values consumed as manifest data).

## 2. Parser + Evaluator Implementation
- [ ] 2.1 Ensure reader preserves `#`-prefixed macro forms and `#`-prefixed macro variables with source positions.
- [ ] 2.2 Implement a manifest parse-macro evaluator with lexical macro-variable scope for sequential expressions.
- [ ] 2.3 Implement built-ins `#Var`, `#If`, `#Eq`, `#Env`, `#Inc` with strict arity/type checks.
- [ ] 2.4 Integrate evaluator into manifest loading flow for `package.gene`.
- [ ] 2.5 Reject unsupported parse-macro forms and non-data runtime execution in manifest mode.

## 3. Validation
- [ ] 3.1 Add parser tests for representative forms:
  - `(#Var #a 1)(#If (#Eq #a 2) A B)`
  - `(#Env HOME)(#Env #name)`
  - `(#Var #i 0)(#Inc #i)`
- [ ] 3.2 Add manifest parsing tests proving environment-dependent output for `package.gene`.
- [ ] 3.3 Add failure tests for unknown macro, unknown variable, and malformed args with filename/line/column diagnostics.
- [ ] 3.4 Run `openspec validate add-manifest-parse-macros --strict`.
