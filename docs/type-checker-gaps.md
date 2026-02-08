# Type Checker Gaps: Compilation → Execution

**Date:** 2026-02-07  
**Status:** Audit of current type checking behavior

## What Works ✅

| Feature | Compile-time | Runtime | Notes |
|---------|:---:|:---:|-------|
| Function param type check | ❌ | ✅ | `(fn f [x: Int] x) (f "bad")` → runtime error |
| Variable declaration type | ❌ | ✅ | `(var x: Int "hello")` → runtime error |
| Variable reassignment | ❌ | ✅ | `(var x: Int 5) (x = "hi")` → runtime error |
| Function return type | ❌ | ✅ | `(fn f [] -> Int "oops") (f)` → runtime error |
| Subclass/inheritance check | ❌ | ✅ | `(fn f [a: Animal] ...) (f dog)` → works for Dog < Animal |
| Gradual typing (mixed) | — | ✅ | `(fn f [x: Int y] ...)` — y accepts anything |
| Explicit `Any` type | — | ✅ | `(fn f [x: Any] ...)` — accepts everything |
| Auto-conversion Int→Float | — | ✅ | `(fn f [x: Float] x) (f 3)` → 3.0 |
| Union types | ❌ | ✅ | `(fn f [x: (Int \| String)] ...)` — runtime validated |
| Function types | ❌ | ✅ | `(fn f [cb: (Fn [Int] Int)] ...)` — runtime validated |
| Lambda type annotations | ❌ | ✅ | `(var f (fn [x: Int] x))` — works at runtime |
| `.is` operator | — | ✅ | `(42 .is Int)` → true |
| Nil allowed for typed vars | — | ✅ | `(var x: Int nil)` → nil (no error) |
| Nil allowed for typed params | — | ✅ | `(fn f [x: Int] x) (f nil)` → nil (no error) |

## Gaps Found 🔴

### Gap 1: Method Return Type Not Checked
**Severity: High**

```gene
(class Foo (method bar [] -> Int "oops"))
((new Foo) .bar)  # Returns "oops" — NO ERROR!
```

Function return types ARE checked, but method return types are NOT. The return type annotation is parsed and stored, but the VM doesn't validate the method's return value.

**Root cause:** `exec.nim` checks return types after function calls (IkReturn), but the method dispatch path (`call_instance_method`) doesn't perform the same check.

### Gap 2: No Compile-Time Type Errors
**Severity: High**

The type checker runs but operates in gradual mode (`strict=false`). It infers types and produces descriptors, but **never emits compile-time errors or warnings** for obviously wrong calls:

```gene
(fn f [x: Int] x)
(var s: String "hi")
(f s)  # Type checker KNOWS s is String and f expects Int — but doesn't warn
```

All type errors are caught at runtime. The type checker does inference but doesn't use it for validation in gradual mode.

**What we want:** Even in gradual mode, emit warnings for provably-wrong calls (where the checker has enough info to know it will fail).

### Gap 3: Property Type Annotations Don't Work
**Severity: High**

```gene
(class Point
  (prop x: Int)
  (prop y: Int)
  (ctor [a b] (/x = a) (/y = b)))
(var p (new Point 1 2))
(p/x = "wrong")  # Should error — but crashes differently
```

`(prop x: Int)` syntax is parsed but the `: Int` annotation is not enforced:
- Not checked on constructor assignment
- Not checked on property mutation
- Property type info isn't stored on the Class object

### Gap 4: Parameterized Collection Types Not Validated
**Severity: Medium**

```gene
(fn f [arr: (Array Int)] arr)
(f [1 "two" 3])  # No error — only checks it's an Array, not element types
```

`(Array Int)` is parsed as an Applied type, but runtime validation only checks the outer type (Array), not the element type parameter. Same for `(Map String Int)`.

### Gap 5: try/catch Can't Catch Type Errors
**Severity: Medium (known bug)**

```gene
(try
  (f "bad")  # Type error
  (catch e (println "caught")))
# CRASHES instead of catching — SIGSEGV in value_core.nim:2280 pop
```

Type errors during function argument processing happen at a stack level where the try/catch handler isn't properly set up. This is a known bug (documented in progress tracking).

### Gap 6: No Source Location on Some Type Errors
**Severity: Low**

```
Error: Type error: expected Int, got String in call
```

Some type errors include source location (`<eval>:1:1:`) while others don't. The variable declaration and assignment paths don't include location. Function call type errors sometimes do (via the function's source trace) and sometimes don't.

### Gap 7: Nil Passes All Type Checks
**Severity: Design Decision Needed**

```gene
(var x: Int nil)     # No error
(fn f [x: Int] x)
(f nil)              # No error
```

Currently nil passes every type check (it's explicitly excluded from validation). This is intentional for gradual typing, but may not be desired. Options:
- Keep as-is (nil is the "zero value" for all types)
- Require `(Int | Nil)` or `(Option Int)` for nullable
- Make nil-checking configurable

### Gap 8: Type Checker Doesn't Track Variable Types Across Statements
**Severity: Medium**

The type checker processes each statement independently. It doesn't build a symbol table across statements, so it can't warn about:

```gene
(var x: String "hello")
(var y: Int x)  # Checker doesn't know x is String here
```

This limits the checker's ability to catch errors at compile time even when type info is available.

## Priority Recommendations

1. **Gap 1 (method return type)** — straightforward fix in VM dispatch path
2. **Gap 3 (property types)** — needed for OOP correctness
3. **Gap 2 (compile-time warnings)** — the type checker does the work but discards the results
4. **Gap 5 (try/catch)** — known bug, needs stack management fix
5. **Gap 6 (source locations)** — polish
6. **Gap 4 (parameterized collections)** — nice to have, complex
7. **Gap 7 (nil semantics)** — design decision
8. **Gap 8 (cross-statement tracking)** — requires checker architecture change
