## Comprehensive benchmark suite for Gene VM performance experiments.
## Uses unrolled call blocks inside `repeat` (like call_burst.nim)
## to minimize loop overhead and isolate the cost of each operation.
##
## Usage: nim c -d:release --mm:orc --opt:speed -r benchmarks/suite.nim

when isMainModule:
  import times, strformat, os, strutils

  import ../src/gene/types
  import ../src/gene/parser
  import ../src/gene/compiler
  import ../src/gene/vm

  const REPEATS = 5000
  const OPS_PER_REPEAT = 100  # unrolled calls per repeat
  const TOTAL_OPS = REPEATS * OPS_PER_REPEAT
  const BENCH_RUNS = 3

  type BenchResult = object
    name: string
    best: float
    opsPerSec: float

  var results: seq[BenchResult]

  proc unroll(line: string, n: int = OPS_PER_REPEAT): string =
    var lines: seq[string]
    for _ in 0..<n:
      lines.add("    " & line)
    lines.join("\n")

  proc runBench(name: string, code: string, totalOps: int = TOTAL_OPS) =
    let parsed = read_all(code)
    let compiled = compile(parsed)

    # Warmup
    init_app_and_vm()
    init_stdlib()
    VM.frame.update(new_frame(new_namespace("w")))
    VM.cu = compiled
    discard VM.exec()

    # Timed — best of N
    var best = float.high
    for _ in 0..<BENCH_RUNS:
      init_app_and_vm()
      init_stdlib()
      VM.frame.update(new_frame(new_namespace("b")))
      VM.cu = compiled
      let t0 = cpuTime()
      discard VM.exec()
      let elapsed = cpuTime() - t0
      if elapsed < best:
        best = elapsed

    let ops = float(totalOps) / best
    results.add(BenchResult(name: name, best: best, opsPerSec: ops))
    echo fmt"{name:<35s} {best*1000:>10.3f} ms   {ops:>14.0f} ops/s"

  echo "Benchmark                              Best ms        Throughput"
  echo repeat('-', 65)

  # --- 1. Function call (1 arg) ---
  runBench("fn_call_1arg", fmt"""
    (fn f1 [n] (n + 1))
    (repeat {REPEATS}
{unroll("(f1 42)")})
  """)

  # --- 2. Function call (5 args) ---
  runBench("fn_call_5args", fmt"""
    (fn f5 [a b c d e] (a + b + c + d + e))
    (repeat {REPEATS}
{unroll("(f5 1 2 3 4 5)")})
  """)

  # --- 3. Method call (1 arg) ---
  runBench("method_call_1arg", fmt"""
    (class C
      (ctor [] (/n = 0))
      (method m1 [v] (/n = (/n + v))))
    (var c (new C))
    (repeat {REPEATS}
{unroll("(c .m1 1)")})
  """)

  # --- 4. Method call (5 args) ---
  runBench("method_call_5args", fmt"""
    (class C
      (ctor [] (/n = 0))
      (method m5 [a b c d e] (/n = (/n + a + b + c + d + e))))
    (var c (new C))
    (repeat {REPEATS}
{unroll("(c .m5 1 2 3 4 5)")})
  """)

  # --- 5. While loop (tight) ---
  runBench("while_loop", """
    (var i 0)
    (while (i < 2000000)
      (i = (i + 1)))
    i
  """, 2_000_000)

  # --- 6. String operations ---
  runBench("string_ops", fmt"""
    (repeat {REPEATS}
{unroll("(var s \"hello\") (s .to_upper)")})
  """)

  # --- 7. Native fn call (1 arg) — typeof ---
  runBench("native_call_1arg", fmt"""
    (repeat {REPEATS}
{unroll("(typeof 42)")})
  """)

  # --- 8. Native method call (1 arg) — array .push ---
  runBench("native_method_1arg", fmt"""
    (var arr [])
    (repeat {REPEATS}
{unroll("(arr .push 1)")})
  """)

  echo repeat('-', 65)
  echo ""

  # Comparison mode
  if paramCount() >= 1 and paramStr(1) == "--compare":
    let baselinePath = "benchmarks/baseline.txt"
    if fileExists(baselinePath):
      echo "Comparison vs baseline:"
      let lines = readFile(baselinePath).splitLines()
      for line in lines:
        if line.len == 0 or line.startsWith("#"):
          continue
        let parts = line.split('\t')
        if parts.len >= 2:
          let bName = parts[0].strip()
          let bTime = parseFloat(parts[1].strip())
          for r in results:
            if r.name == bName:
              let pct = (bTime - r.best) / bTime * 100
              let marker = if pct > 0.5: " FASTER" elif pct < -0.5: " SLOWER" else: ""
              echo fmt"  {bName:<35s} {pct:>+6.1f}%{marker}"
      echo ""

  # Machine-readable table
  echo "# Machine-readable results (name<TAB>best_seconds)"
  for r in results:
    echo r.name & "\t" & fmt"{r.best:.6f}"
