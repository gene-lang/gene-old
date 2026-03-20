# Ongoing Cleanup

Living document tracking cleanup work across design, implementation, documentation, and project organization. The goal: a well-defined language spec, skills ready to use, and a language definition usable from VS Code.

## Priority Guide

- **P0** — foundational work that clarifies the language and unblocks everything else
- **P1** — important follow-on work that improves usability, tooling, and docs quality
- **P2** — structural cleanup and hygiene that matters, but can follow once the foundations are stable

## P0 — Foundation / Highest Leverage

### Canonical Language Reference & Spec
- [ ] Create `spec/` directory for the canonical language specification
- [ ] Write a proper **Language Reference** (or promote `examples/full.gene` into a structured spec)
- [ ] Define core syntax (S-expressions, literals, comments, quoting)
- [ ] Define type system (built-in types, type annotations, gradual typing)
- [ ] Define evaluation rules (scoping, closures, tail calls)
- [ ] Define OOP model (classes, methods, constructors, inheritance)
- [ ] Define control flow (if/elif/else, loops, try/catch, pattern matching)
- [ ] Define macro system
- [ ] Define module/namespace system
- [ ] Define async/await semantics

### Accuracy Audit & Spec/Test Alignment
- [ ] Walk each doc and verify it reflects current implementation (not aspirational designs from months ago)
- [ ] Mark speculative/future docs clearly (e.g. `wasm.md`, `simd_support.md`, `native-codegen-design.md`)
- [ ] Remove or archive docs for features that were abandoned or superseded
- [ ] Ensure every spec item has corresponding tests in `testsuite/`
- [ ] Tag test files with the spec section they cover
- [ ] Identify untested language features

### Core Project Entry Points
- [ ] Ensure `README.md` gives an accurate project overview
- [ ] Update `docs/README.md` index after consolidation

## P1 — Important Next

### Documentation Consolidation & Missing Docs
- [ ] Merge overlapping docs: `ai-first.md` vs `ai-first-design.md`, `thread_support.md` vs `threading.md`, `selector_design.md` vs `dynamic_selector_design.md` vs `dispatch-design.md` vs `dynamic_method_dispatch.md`
- [ ] Merge `type-serialization.md` / `type-serialization-design.md` / `serialization_design.md` / `json_serialization.md` into one serialization doc
- [ ] Merge `package_support.md` and `packaging.md`
- [ ] Consolidate `oop_inheritance.md` / `oop_updated_design.md` / `constructor_design.md` into one OOP design doc
- [ ] Review `notes.md` — promote useful content, archive or delete the rest
- [ ] Document all built-in functions and standard library namespaces
- [ ] Document error handling patterns and known limitations
- [ ] Add a "Getting Started" tutorial

### VS Code / Editor Integration

Existing extension: `tools/vscode-extension/` (v0.1.0, packaged as `.vsix`)

- [ ] Audit current TextMate grammar in `tools/vscode-extension/syntaxes/` — ensure it covers all current syntax
  - Verify: map key prefix `^`, property access `/`, `/.` method shorthand
  - Verify: all keywords (`var`, `fn`, `class`, `method`, `ctor`, `if`, `elif`, `else`, `for`, `while`, `do`, `try`, `catch`, `throw`, `return`, `import`, `async`, `await`, `new`, `macro`, `ns`)
- [ ] Review `language-configuration.json` — brackets, auto-close, comment toggling
- [ ] Add snippet definitions for common patterns (class, fn, if/else, try/catch)
- [ ] Bump version and rebuild `.vsix` after updates
- [ ] Review current `docs/lsp.md` — assess what's implemented vs planned
- [ ] Prioritize: diagnostics > hover > completion > goto-definition
- [ ] Connect LSP to the existing compiler pipeline for real-time feedback

### Examples, Build & Tooling Coverage
- [ ] Ensure `nimble test` covers all critical paths
- [ ] Audit `examples/` — remove broken or outdated examples
- [ ] Ensure all examples run with current `bin/gene`
- [ ] Organize examples by topic (basics, OOP, async, IO, etc.)

## P2 — Structural Cleanup / Later

### Source Organization & Internal Cleanup
- [ ] Audit `src/gene/` module structure — identify oversized files that should be split
- [ ] Review `types.nim` — it holds too many concerns (values, instructions, app state)
- [ ] Clean up dead code paths (unused instructions, deprecated helpers)
- [ ] Standardize error messages and error handling patterns

### Build / Repo Hygiene
- [ ] Review `gene.nimble` — clean up unused tasks, document remaining ones
- [ ] Audit `scripts/` and `tools/` — remove obsolete scripts
- [ ] Review and clean `tmp/`, `build/` gitignore rules
- [ ] Audit `openspec/changes/` — archive completed changes
- [ ] Clean up `CLAUDE.md` / `AGENTS.md` if they contain stale info

### Skills / Reusable Patterns
- [ ] Identify common patterns that should become library functions
- [ ] Document the extension authoring workflow (native functions, `genex/` namespace)
- [ ] Create skill templates for AI agent consumption (Claude Code, Copilot, etc.)

## Progress Log

Track completed cleanup work here with dates:

<!-- Example:
- 2026-03-20: Merged thread_support.md and threading.md into threading.md
-->

## Agent Comments

- Prioritize a canonical language reference early; a lot of cleanup becomes easier once one document is the source of truth.
- `examples/full.gene` is already acting as a de facto syntax reference, so promoting it into structured spec/docs should be high leverage.
- Documentation cleanup and test-spec alignment should probably move together; otherwise it is easy to rewrite docs without proving current behavior.
- The VS Code grammar audit looks especially valuable because the language has several syntax forms (`^`, `/`, `/.`) that are easy for tooling to drift on.
- `types.nim` is a strong candidate for incremental decomposition, but that work should likely happen after the spec/docs are clearer so refactors follow stable boundaries.
- It may help to split this checklist into “high-leverage first” vs “later structural cleanup” so the project does not treat all items as equally urgent.
