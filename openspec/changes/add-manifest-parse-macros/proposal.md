## Why
`package.gene` and similar metadata files are currently static. Teams need environment-aware metadata (for example, conditional dependency settings by CI/host environment) without executing full runtime code.

Gene already tokenizes `#`-prefixed symbols, but there is no defined parse-time macro evaluator for manifest contexts. As a result, forms like `(#If ...)`, `(#Env ...)`, and variable-style parse macros cannot drive manifest output.

## What Changes
- Add a manifest parse-macro capability for parse-macro-enabled files (starting with `package.gene`).
- Define parser/evaluator behavior for `#`-prefixed macro calls and `#`-prefixed macro variables.
- Define initial built-in parse macros: `#Var`, `#If`, `#Eq`, `#Env`, and `#Inc`.
- Define safety boundaries: parse-macro evaluation is data-oriented and does not execute arbitrary runtime functions.
- Define error semantics for unknown macros, unknown macro variables, and invalid argument shapes.

## Impact
- Affected specs: `manifest-parse-macros`
- Affected code: `src/gene/parser.nim` (macro-form recognition behavior), new manifest parse-macro evaluator module, package manifest loading path, tests for parser/manifest parsing
