# Gene Integration Tests

This directory contains broader Nim tests that are not unit tests:

- language/runtime semantics that are still expressed as Nim tests
- CLI behavior
- module/package loading
- stdlib integration coverage
- thread/async/runtime integration
- app/network/provider-specific integrations

## Running

```bash
# Local/runtime integration tests
nimble testintegration

# App/network/external integrations
nimble testapp
```

## Notes

- Many files here still use `../helpers.nim` for shared setup helpers.
- If a behavior can be covered as a runnable Gene program and does not need Nim-only hooks, prefer `testsuite/`.
- If a test needs direct Nim access to CLI/runtime internals but is broader than a unit test, it belongs here.
