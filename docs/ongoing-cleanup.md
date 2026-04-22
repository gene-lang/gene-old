# Ongoing Cleanup

Living document tracking cleanup work across design, implementation, documentation, and project organization. The goal: a well-defined language spec, skills ready to use, and a language definition usable from VS Code.

## Priority Guide

- **P0** — foundational work that clarifies the language and unblocks everything else
- **P1** — important follow-on work that improves usability, tooling, and docs quality
- **P2** — structural cleanup and hygiene that matters, but can follow once the foundations are stable

## P0 — Foundation / Highest Leverage

### Canonical Language Reference & Spec
- [x] Create `spec/` directory for the canonical language specification
- [x] Write a proper **Language Reference** (now `spec/README.md` plus sections `01`-`17`)
- [x] Define core syntax (S-expressions, literals, comments, quoting)
- [x] Define type system (built-in types, type annotations, gradual typing)
- [x] Define evaluation rules (scoping, closures, tail calls)
- [x] Define OOP model (classes, methods, constructors, inheritance)
- [x] Define control flow (if/elif/else, loops, try/catch, pattern matching)
- [x] Define macro system
- [x] Define module/namespace system
- [x] Define async/await semantics

### Accuracy Audit & Spec/Test Alignment
- [ ] Walk each doc and verify it reflects current implementation (not aspirational designs from months ago)
- [x] Mark genuinely speculative/future docs clearly (moved proposal docs under `docs/proposals/future/`)
- [x] Label implemented subsystems with design-era docs separately from future work (moved them under `docs/proposals/implemented/`)
- [x] Remove or archive docs for features that were abandoned or superseded
- [ ] Ensure every spec item has corresponding tests in `testsuite/`
- [ ] Tag test files with the spec section they cover
- [ ] Identify untested language features

### Core Project Entry Points
- [ ] Ensure `README.md` gives an accurate project overview
- [x] Update `docs/README.md` index after consolidation

## P1 — Important Next

### Documentation Consolidation & Missing Docs
- [ ] Merge overlapping docs: `proposals/future/ai-first.md` vs `proposals/future/ai-first-design.md`, `proposals/future/selector_design.md` vs `proposals/future/dynamic_selector_design.md` vs `proposals/implemented/dispatch-design.md` vs `proposals/future/dynamic_method_dispatch.md`
- [ ] Merge `proposals/future/type-serialization.md` / `proposals/future/type-serialization-design.md` / `proposals/future/serialization_design.md` / `proposals/future/json_serialization.md` into one serialization doc
- [ ] Merge `package_support.md` and `proposals/future/packaging.md`
- [ ] Consolidate `proposals/future/oop_inheritance.md` / `proposals/future/oop_updated_design.md` / `proposals/future/constructor_design.md` into one OOP design doc
- [x] Review `NOTES.md` — promote useful content, archive or delete the rest
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
- [x] Review current `docs/lsp.md` — assess what's implemented vs planned
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
- 2026-03-20: Refreshed the docs index after moving proposal docs under docs/proposals/
-->

- 2026-03-23: Reclassified `wasm.md` as implementation-facing and `docs/proposals/implemented/native-codegen-design.md` as an implemented subsystem doc that still needs an accuracy refresh.
- 2026-03-23: Added explicit status banners to the old threading design note and `docs/proposals/implemented/native-codegen-design.md` to distinguish them from canonical implementation docs.
- 2026-03-23: Updated `testsuite/README.md`, `testsuite/TEST_ORGANIZATION.md`, and `testsuite/stdlib/README.md` to match the current test layout instead of the old 14-test structure.
- 2026-03-23: Confirmed there is currently no spec-section tagging convention in `testsuite/`; `# Expected:`, `# ExitCode:`, and `# Args:` are the only standardized metadata headers.
- 2026-03-23: Initial spec/test audit: `testsuite/` covers most major spec areas, but destructuring edge cases and thread messaging APIs are still covered mainly in Nim tests rather than runnable `testsuite/` programs.
- 2026-03-23: Reorganized `testsuite/` so the default runner follows `spec/` section numbering (`01-syntax` through `15-serialization`), added dedicated section coverage for errors, patterns, regex, serialization, and thread-style async replies, and restored the full `testsuite/run_tests.sh` pass to green.
- 2026-03-23: Moved proposal/design/history docs out of the `docs/` root into `docs/proposals/{future,implemented,archive}/` and rewrote `docs/README.md` so the root docs now skew toward current implementation/reference material.
- 2026-03-23: Demoted scratch and design-era leftovers out of the `docs/` root (`NOTES`, `development_notes`, `dispatch-design`, `symbol_resolution`) and rewrote the HTTP, benchmark, and LSP docs around current code paths.
- 2026-03-23: Documented the current spec-coverage gap in `docs/README.md`: compiler internals, GIR, wasm, HTTP/C extensions, and LSP are still implementation-only docs rather than `spec/` sections.
- 2026-04-02: Re-reviewed the cleanup tracker against the current repo state and marked the canonical spec foundation items complete now that `spec/README.md` and sections `01`-`17` exist as the language reference.
- 2026-04-02: Re-reviewed `docs/lsp.md`; it now clearly documents the current `gene lsp` implementation surface (sync, completion, definition, hover, references, workspace symbol search) versus missing features, so that checklist item is complete.
- 2026-04-02: Kept spec/test alignment tasks open because `testsuite/` still has no per-file spec-section metadata beyond `# Expected:`, `# ExitCode:`, and `# Args:`, and the numbered suite currently stops at `15-serialization` while `spec/` also includes `16-comptime` and `17-selectors`.

## Agent Comments

- Prioritize a canonical language reference early; a lot of cleanup becomes easier once one document is the source of truth.
- `examples/full.gene` is already acting as a de facto syntax reference, so promoting it into structured spec/docs should be high leverage.
- Documentation cleanup and test-spec alignment should probably move together; otherwise it is easy to rewrite docs without proving current behavior.
- The VS Code grammar audit looks especially valuable because the language has several syntax forms (`^`, `/`, `/.`) that are easy for tooling to drift on.
- `types.nim` is a strong candidate for incremental decomposition, but that work should likely happen after the spec/docs are clearer so refactors follow stable boundaries.
- It may help to split this checklist into “high-leverage first” vs “later structural cleanup” so the project does not treat all items as equally urgent.
- `wasm.md` currently looks implementation-facing and should stay in the accuracy audit bucket, not the speculative-doc bucket.
- Native compilation is implemented and tested, but docs like `proposals/implemented/native-codegen-design.md` still read as design notes; treat them as “implemented but needs refresh,” not “future-only.”
- The testsuite docs had significant drift; keeping `testsuite/README.md` and `testsuite/TEST_ORGANIZATION.md` current is part of the same accuracy-audit work as refreshing `spec/`.
- The current strongest spec/test gaps appear to be: no standardized spec tags in test files, limited runnable `testsuite/` coverage for destructuring patterns, and thread messaging APIs that are mostly validated in Nim tests.
