# Gene Language Specification

Version: 0.1 (Draft)
Date: 2026-03-20

This directory contains the canonical language specification for Gene, a homoiconic Lisp-like language implemented in Nim with a bytecode VM.

## Sections

1. [Syntax & Literals](01-syntax.md) — S-expressions, comments, primitives, quoting
2. [Types](02-types.md) — Value types, type annotations, gradual typing
3. [Expressions & Operators](03-expressions.md) — Arithmetic, comparison, logical, assignment
4. [Control Flow](04-control-flow.md) — if/elif/else, loops, case/when
5. [Functions](05-functions.md) — Definition, arguments, closures, macros
6. [Collections](06-collections.md) — Arrays, maps, Gene values, spread
7. [Object-Oriented Programming](07-oop.md) — Classes, methods, inheritance, namespaces
8. [Modules & Namespaces](08-modules.md) — Import, export, namespace system
9. [Error Handling & Contracts](09-errors.md) — try/catch, throw, pre/postconditions
10. [Async & Concurrency](10-async.md) — Futures, async/await, actors, and the public concurrency surface
11. [Generators](11-generators.md) — Generator functions, yield, iteration protocol
12. [Pattern Matching](12-patterns.md) — Destructuring, case/when, enum ADTs
13. [Regular Expressions](13-regex.md) — Regex literals, matching, replacement
14. [Standard Library](14-stdlib.md) — Built-in functions, I/O, string methods, collections
15. [Serialization](15-serialization.md) — JSON, GIR, type serialization
16. [Compile-Time Evaluation](16-comptime.md) — comptime blocks, conditional compilation, code emission
17. [Selectors](17-selectors.md) — Unified path access, selector values, stream selection

Each section includes a **Potential Improvements** subsection documenting known rough edges, design questions, and ideas for future refinement.
