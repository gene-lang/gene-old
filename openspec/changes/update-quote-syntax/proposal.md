## Why
Quote is currently bound to `:` which prevents using leading-colon symbols (`:foo`) and conflicts with keyword-style tokens. Moving quote to backtick aligns with common Lisp syntax and frees `:` for symbol use while keeping quote/unquote behavior intact.

## What Changes
- **BREAKING**: Replace `:` quote prefix with backtick (`) for quoting the next form.
- Treat `:` as a normal symbol constituent; `:a` becomes a symbol named `:a`.
- Update parser, tests, docs, and tooling to use the new quote prefix.

## Impact
- Affected code: `src/gene/parser.nim`, docs/examples/tests, editor grammar.
- Affected behavior: reader/lexer for quote syntax and symbol tokenization.
