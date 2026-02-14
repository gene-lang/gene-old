## 1. OpenSpec
- [x] 1.1 Define stdlib modularization requirements and module boundaries.
- [x] 1.2 Validate proposal with `openspec validate refactor-stdlib-module-split --strict`.

## 2. Implementation
- [x] 2.1 Extract `classes.nim` (Object/class hierarchy helpers, `init_basic_classes`, class setup utilities).
- [x] 2.2 Extract `regex.nim` (regex cache/helpers and `init_regex_class`).
- [x] 2.3 Extract `json.nim` (JSON parse/stringify helpers and namespace setup).
- [x] 2.4 Extract `strings.nim` (`init_string_class` and string methods).
- [x] 2.5 Extract `collections.nim` (Array/Map/Set class initializers and methods).
- [ ] 2.6 Extract `dates.nim` (Date/DateTime classes and date-related functions).
- [ ] 2.7 Extract `selectors.nim` (`init_selector_class`).
- [ ] 2.8 Extract `gene_meta.nim` (`init_gene_and_meta_classes`).
- [ ] 2.9 Extract `aspects.nim` (AOP macro/application/interception setup).
- [ ] 2.10 Extract `core.nim` (core builtins, VM utilities, env/base64/scheduler helpers, namespace wiring) and thin `src/gene/stdlib.nim` orchestrator.

## 3. Validation
- [ ] 3.1 After each extraction step: run `PATH=$HOME/.nimble/bin:$PATH nimble build`.
- [ ] 3.2 After each extraction step: run `./testsuite/run_tests.sh`.
- [ ] 3.3 Final pass: run `PATH=$HOME/.nimble/bin:$PATH nimble build` and `./testsuite/run_tests.sh` on thin-orchestrator layout.
