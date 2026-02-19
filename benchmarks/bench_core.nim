import std/[times, strformat, osproc, json]
import ../src/[parser, compiler, vm, ffi]

const
  WarmupRounds = 2
  MeasureRounds = 5

type
  BenchRow = object
    name: string
    geneMs: float64
    pythonMs: float64

proc runGene(source: string): float64 =
  let ast = parseProgram(source, "<bench>")
  let module = compileProgram(ast, "<bench>")

  for _ in 0..<WarmupRounds:
    var runtime = newVm()
    registerDefaultNatives(runtime)
    discard runtime.runModule(module)

  var best = Inf
  for _ in 0..<MeasureRounds:
    var runtime = newVm()
    registerDefaultNatives(runtime)
    let t0 = cpuTime()
    discard runtime.runModule(module)
    let elapsedMs = (cpuTime() - t0) * 1000.0
    if elapsedMs < best:
      best = elapsedMs
  best

proc loadPythonBaseline(): JsonNode =
  let (output, code) = execCmdEx("python3 benchmarks/python_baseline.py")
  if code != 0:
    quit("python baseline failed:\n" & output, QuitFailure)
  try:
    parseJson(output)
  except CatchableError as ex:
    quit("invalid python baseline output: " & ex.msg & "\n" & output, QuitFailure)

proc pythonMs(node: JsonNode; key: string): float64 =
  if not node.hasKey(key):
    quit("python baseline missing key: " & key, QuitFailure)
  node[key].getFloat()

proc printRows(rows: seq[BenchRow]) =
  echo ""
  echo "Benchmark                Gene(ms)    Python(ms)   Gene/Python"
  echo "--------------------------------------------------------------"
  for row in rows:
    let ratio =
      if row.pythonMs <= 0.0:
        0.0
      else:
        row.geneMs / row.pythonMs
    echo fmt"{row.name:<22} {row.geneMs:>9.2f} {row.pythonMs:>12.2f} {ratio:>12.3f}x"
  echo ""

proc main() =
  let geneFib = """
    (fn fib [n]
      (if (n <= 1) n
      else ((fib (n - 1)) + (fib (n - 2)))))
    (var out 0)
    (repeat 200
      (out = (fib 20)))
    out
  """

  let geneArray = """
    (var arr [])
    (repeat 40000
      (arr .push 1))
    (var total 0)
    (for x in arr
      (total += x))
    total
  """

  let geneDispatch = """
    (class Counter
      (ctor [base]
        (/base = base))
      (method bump [x]
        (/base + x)))
    (var c (new Counter 1))
    (var out 0)
    (repeat 200000
      (out = (c .bump 1)))
    out
  """

  let py = loadPythonBaseline()

  var rows: seq[BenchRow] = @[]
  rows.add(BenchRow(name: "fib(20) x200", geneMs: runGene(geneFib), pythonMs: pythonMs(py, "fib")))
  rows.add(BenchRow(name: "array push/sum", geneMs: runGene(geneArray), pythonMs: pythonMs(py, "array")))
  rows.add(BenchRow(name: "class dispatch", geneMs: runGene(geneDispatch), pythonMs: pythonMs(py, "dispatch")))

  printRows(rows)

when isMainModule:
  main()
