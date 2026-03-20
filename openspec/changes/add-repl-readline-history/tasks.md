# Implementation Tasks: Add Readline History Support To REPL

## 1. Interactive Input Backend
- [x] 1.1 Add a readline-compatible interactive input path for REPL sessions.
- [x] 1.2 Keep the current plain line reader as the fallback for non-interactive sessions or unsupported builds.

## 2. History Behavior
- [x] 2.1 Record non-empty REPL inputs in session history so up/down navigation works.
- [x] 2.2 Enable reverse history search with `Ctrl-R` through the interactive backend.

## 3. Validation
- [x] 3.1 Add tests for any non-interactive history/fallback logic that can be validated automatically.
- [x] 3.2 Verify the OpenSpec change with strict validation.
