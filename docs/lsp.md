# Gene LSP

Gene ships an LSP server through the `gene lsp` command.

This document describes the current implementation in `src/commands/lsp.nim`
and `src/gene/lsp/`. It is an implementation note, not a language-spec
document.

## Startup Modes

Default mode is stdio:

```bash
gene lsp
```

Useful flags:

- `--stdio` - explicit stdio mode
- `--tcp` - TCP server mode for manual debugging
- `--port <port>` - TCP port, default `8080`
- `--host <host>` - TCP host, default `localhost`
- `--workspace <dir>` - set workspace root
- `--trace` - emit trace logs

## Current Server Capabilities

The server advertises:

- text document sync
- completion
- definition
- hover
- references
- workspace symbol search

Current request handling exists for:

- `initialize`
- `shutdown`
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didSave`
- `textDocument/didClose`
- `textDocument/completion`
- `textDocument/definition`
- `textDocument/hover`
- `textDocument/references`
- `workspace/symbol`

## How It Works

The implementation keeps a document cache in `src/gene/lsp/document.nim` and
re-parses Gene source on open/change/save. Language features are built on that
parsed document state.

Today it provides:

- parser-backed diagnostics
- document symbol extraction
- basic completion items
- definition lookup
- hover text
- reference search
- workspace symbol search

## Current Limits

The current LSP is intentionally lightweight:

- no formatter
- no rename support
- no signature help
- no code actions
- no type-checker-backed semantic analysis
- completion and navigation are only as precise as the current document parser
  and symbol extractor

Syntax highlighting is not provided by the LSP server itself. That remains an
editor-grammar concern.

## Quick Verification

```bash
./bin/gene lsp --help
./bin/gene lsp --trace
```
