# benchmarks/bench_calls.nim
#
# Gene VM Call-Type Benchmark Framework
# ======================================
# Measures per-call overhead for four invocation styles:
#   1. Function call        — (fn add [a b] (+ a b))  →  (add 1 2)
#   2. Method call          — (class C (method add [a b] ...))  →  (c .add 1 2)
#   3. Native function call — native "len" registered in Nim  →  (len arr)
#   4. Native method call   — native via method dispatch      →  (arr .push 4)
#
# Strategy:  (repeat 1000  (f ...)(f ...)...100 times... )
# Duplicating the call expression 100× inside the repeat body eliminates
# loop-counter overhead so the measurement reflects pure call dispatch.
#
# Build & run:
#   nim c -d:release -o:bin/bench_calls benchmarks/bench_calls.nim
#   ./bin/bench_calls
#
# Or via nimble:
#   nimble bench

import std/[times, strutils, strformat, math, sequtils]
import ../src/[types, parser, ir, compiler, vm, ffi]

# ─── Helpers ──────────────────────────────────────────────────────────

const
  WarmupIterations  = 5       ## Warm-up rounds (results discarded)
  BenchmarkRounds   = 5       ## Measured rounds (best of N)
  RepeatOuter       = 1_000   ## outer (repeat N ...) count
  DuplicateInner    = 100     ## number of duplicated call exprs per body
  TotalCalls        = RepeatOuter * DuplicateInner  # 100_000 per benchmark

type
  BenchResult = object
    name: string
    iterations: int
    totalMs: float64       ## Best-of-N wall time in milliseconds
    opsPerSec: float64     ## iterations / totalMs * 1000

proc dup(callExpr: string; n: int): string =
  ## Duplicate a call expression n times, separated by newlines.
  var parts = newSeq[string](n)
  for i in 0 ..< n:
    parts[i] = "  " & callExpr
  parts.join("\n")

proc runGeneSource(source: string): float64 =
  ## Compile and execute a Gene program, returning best-of-N wall-clock ms.
  let ast = parseProgram(source, "<bench>")
  let module = compileProgram(ast, "<bench>")

  # Warm-up
  for warmup in 0 ..< WarmupIterations:
    var rt = newVm()
    registerDefaultNatives(rt)
    discard rt.runModule(module)

  # Measured
  var bestMs = Inf
  for round in 0 ..< BenchmarkRounds:
    var rt = newVm()
    registerDefaultNatives(rt)
    let t0 = cpuTime()
    discard rt.runModule(module)
    let elapsed = (cpuTime() - t0) * 1000.0
    if elapsed < bestMs:
      bestMs = elapsed

  bestMs

proc bench(name, source: string; iterations: int): BenchResult =
  let ms = runGeneSource(source)
  BenchResult(
    name: name,
    iterations: iterations,
    totalMs: ms,
    opsPerSec: iterations.float64 / ms * 1000.0
  )

proc formatOps(ops: float64): string =
  if ops >= 1_000_000:
    fmt"{ops / 1_000_000:.2f}M"
  elif ops >= 1_000:
    fmt"{ops / 1_000:.2f}K"
  else:
    fmt"{ops:.0f}"

proc printResults(results: seq[BenchResult]) =
  let maxOps = results.mapIt(it.opsPerSec).foldl(max(a, b))

  echo ""
  echo "╔══════════════════════════════════╦══════════════╦══════════════╦══════════╗"
  echo "║ Benchmark                        ║   ops/sec    ║   total ms   ║ relative ║"
  echo "╠══════════════════════════════════╬══════════════╬══════════════╬══════════╣"
  for r in results:
    let rel = r.opsPerSec / maxOps * 100.0
    let nameField = alignLeft(r.name, 32)
    let opsField  = align(formatOps(r.opsPerSec), 12)
    let msField   = align(fmt"{r.totalMs:.2f}", 12)
    let relField  = align(fmt"{rel:.1f}%", 8)
    echo fmt"║ {nameField} ║ {opsField} ║ {msField} ║ {relField} ║"
  echo "╚══════════════════════════════════╩══════════════╩══════════════╩══════════╝"
  echo ""

# ─── Benchmark Definitions ───────────────────────────────────────────

proc benchFunctionCall(): BenchResult =
  ## Gene-defined function, called in a tight loop.
  let calls = dup("(add 1 2)", DuplicateInner)
  let source = fmt"""
(fn add [a b] (+ a b))
(repeat {RepeatOuter}
{calls})
"""
  bench("Function call", source, TotalCalls)

proc benchMethodCall(): BenchResult =
  ## Method dispatch on a Gene class instance.
  let calls = dup("(c .add 1 2)", DuplicateInner)
  let source = fmt"""
(class Calc
  (ctor [x]
    (/x = x))
  (method add [a b]
    (+ a b)))
(var c (new Calc 0))
(repeat {RepeatOuter}
{calls})
"""
  bench("Method call", source, TotalCalls)

proc benchNativeFunctionCall(): BenchResult =
  ## Call to a Nim-registered native function (len is cheap & side-effect-free).
  let calls = dup("(len arr)", DuplicateInner)
  let source = fmt"""
(var arr [1 2 3])
(repeat {RepeatOuter}
{calls})
"""
  bench("Native function call", source, TotalCalls)

proc benchNativeMethodCall(): BenchResult =
  ## Native method dispatch — array .push goes through invokeArrayMethod.
  let calls = dup("(arr .push 4)", DuplicateInner)
  let source = fmt"""
(var arr [1 2 3])
(repeat {RepeatOuter}
{calls})
"""
  bench("Native method call", source, TotalCalls)

# ─── Additional micro-benchmarks ─────────────────────────────────────

proc benchRecursiveCall(): BenchResult =
  ## Recursive function calls (fibonacci-like, bounded depth).
  ## Each fib(10) does ~177 sub-calls, so we use fewer outer reps.
  let outerN = RepeatOuter div 10    # 100 outer
  let innerN = DuplicateInner div 10 # 10 inner
  let totalN = outerN * innerN       # 1_000 top-level calls × ~177 sub-calls each
  let calls = dup("(fib 10)", innerN)
  let source = fmt"""
(fn fib [n]
  (if (n <= 1) n
  else ((fib (n - 1)) + (fib (n - 2)))))
(repeat {outerN}
{calls})
"""
  bench("Recursive call (fib 10)", source, totalN)

proc benchClosureCall(): BenchResult =
  ## Closure invocation — tests upvalue capture overhead.
  let calls = dup("(add5 10)", DuplicateInner)
  let source = fmt"""
(fn make_adder [x]
  (fn [y] (+ x y)))
(var add5 (make_adder 5))
(repeat {RepeatOuter}
{calls})
"""
  bench("Closure call", source, TotalCalls)

proc benchHigherOrderCall(): BenchResult =
  ## Higher-order function: passing function as argument.
  let calls = dup("(apply double 21)", DuplicateInner)
  let source = fmt"""
(fn apply [f x] (f x))
(fn double [x] (* x 2))
(repeat {RepeatOuter}
{calls})
"""
  bench("Higher-order call", source, TotalCalls)

proc benchConstructorCall(): BenchResult =
  ## Object construction = class instantiation + ctor method call.
  let outerN = RepeatOuter div 10  # scale down – construction allocates
  let totalN = outerN * DuplicateInner
  let calls = dup("(new Point 3 4)", DuplicateInner)
  let source = fmt"""
(class Point
  (ctor [x y]
    (/x = x)
    (/y = y)))
(repeat {outerN}
{calls})
"""
  bench("Constructor call (new)", source, totalN)

# ─── Main ────────────────────────────────────────────────────────────

proc main() =
  echo "Gene VM Call Benchmark"
  echo "======================"
  echo fmt"Pattern: (repeat {RepeatOuter}  <call> × {DuplicateInner})"
  echo fmt"Total calls per benchmark: {TotalCalls:>10}"
  echo fmt"Warm-up rounds:            {WarmupIterations:>10}"
  echo fmt"Measured rounds (best):    {BenchmarkRounds:>10}"
  echo ""

  var results: seq[BenchResult]

  echo "Running: Function call..."
  results.add benchFunctionCall()

  echo "Running: Method call..."
  results.add benchMethodCall()

  echo "Running: Native function call..."
  results.add benchNativeFunctionCall()

  echo "Running: Native method call..."
  results.add benchNativeMethodCall()

  echo ""
  echo "── Core Call Types ──"
  printResults(results)

  # Extended benchmarks
  var extResults: seq[BenchResult]

  echo "Running: Recursive call..."
  extResults.add benchRecursiveCall()

  echo "Running: Closure call..."
  extResults.add benchClosureCall()

  echo "Running: Higher-order call..."
  extResults.add benchHigherOrderCall()

  echo "Running: Constructor call..."
  extResults.add benchConstructorCall()

  echo ""
  echo "── Extended Call Patterns ──"
  printResults(extResults)

  # Combined summary
  echo "── All Results ──"
  printResults(results & extResults)

when isMainModule:
  main()
