## Comprehensive benchmark suite for Gene VM performance experiments.
## Usage: nim c -d:release --mm:orc --opt:speed -r benchmarks/suite.nim
##
## Outputs a machine-readable results table to stdout.

when isMainModule:
  import times, strformat, os, strutils

  import ../src/gene/types
  import ../src/gene/parser
  import ../src/gene/compiler
  import ../src/gene/vm

  const WARMUP_RUNS = 1
  const BENCH_RUNS  = 3

  type BenchResult = object
    name: string
    best: float       # seconds
    opsPerSec: float

  var results: seq[BenchResult]

  proc bench(name: string, code: string, expectedOps: int) =
    let parsed = read_all(code)
    let compiled = compile(parsed)

    # Warmup
    for _ in 0..<WARMUP_RUNS:
      init_app_and_vm()
      init_stdlib()
      let ns = new_namespace("bench")
      VM.frame.update(new_frame(ns))
      VM.cu = compiled
      discard VM.exec()

    # Timed runs — take best of N
    var best = float.high
    for _ in 0..<BENCH_RUNS:
      init_app_and_vm()
      init_stdlib()
      let ns = new_namespace("bench")
      VM.frame.update(new_frame(ns))
      VM.cu = compiled
      let t0 = cpuTime()
      discard VM.exec()
      let elapsed = cpuTime() - t0
      if elapsed < best:
        best = elapsed

    let ops = float(expectedOps) / best
    results.add(BenchResult(name: name, best: best, opsPerSec: ops))
    echo fmt"{name:<35s} {best*1000:>10.3f} ms   {ops:>14.0f} ops/s"

  echo "Benchmark                              Best ms        Throughput"
  echo repeat('-', 65)

  # --- 1. Function call (1 arg) ---
  bench("fn_call_1arg", """
    (fn inc [n] (n + 1))
    (var i 0)
    (while (i < 500000)
      (i = (inc i)))
    i
  """, 500_000)

  # --- 2. Function call (5 args) ---
  bench("fn_call_5args", """
    (fn sum5 [a b c d e] (a + b + c + d + e))
    (var i 0)
    (while (i < 500000)
      (i = (i + (sum5 1 1 1 1 1))))
    i
  """, 500_000)

  # --- 3. Method call (1 arg) ---
  bench("method_call_1arg", """
    (class Counter
      (ctor [n] (/n = n))
      (method inc [v] (/n = (/n + v)) /n))
    (var c (new Counter 0))
    (var i 0)
    (while (i < 500000)
      (c .inc 1)
      (i = (i + 1)))
    i
  """, 500_000)

  # --- 4. Method call (5 args) ---
  bench("method_call_5args", """
    (class Acc
      (ctor [] (/n = 0))
      (method add5 [a b c d e] (/n = (/n + a + b + c + d + e)) /n))
    (var a (new Acc))
    (var i 0)
    (while (i < 500000)
      (a .add5 1 1 1 1 1)
      (i = (i + 1)))
    i
  """, 500_000)

  # --- 5. While loop (tight) ---
  bench("while_loop", """
    (var i 0)
    (while (i < 2000000)
      (i = (i + 1)))
    i
  """, 2_000_000)

  # --- 6. String operations ---
  bench("string_ops", """
    (var i 0)
    (while (i < 200000)
      (var s "hello")
      (var u (s .to_upper))
      (var l (u .to_lower))
      (i = (i + 1)))
    i
  """, 200_000)

  # --- 7. Native fn call (1 arg) — typeof ---
  bench("native_call_1arg", """
    (var i 0)
    (while (i < 500000)
      (typeof i)
      (i = (i + 1)))
    i
  """, 500_000)

  # --- 8. Native fn call (5 args) — arithmetic expression ---
  bench("native_call_5args", """
    (fn wrap5 [a b c d e]
      (a + b + c + d + e))
    (var i 0)
    (while (i < 500000)
      (i = (i + (wrap5 1 1 1 1 1))))
    i
  """, 500_000)

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

  # Machine-readable table (for saving as baseline)
  echo "# Machine-readable results (name<TAB>best_seconds)"
  for r in results:
    echo r.name & "\t" & fmt"{r.best:.6f}"
