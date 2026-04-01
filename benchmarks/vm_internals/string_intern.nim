## Benchmark: string literal push performance with interning.
##
## Measures iterations/second for a hot loop that repeatedly pushes and uses
## string literals. The intern table deduplicates string literals at parse/compile
## time (one ptr String per unique literal), while IkPushValue still copies on
## each push to give variables a private mutable object.

when isMainModule:
  import times, strformat

  import ../../src/gene/types
  import ../../src/gene/parser
  import ../../src/gene/compiler
  import ../../src/gene/vm

  const ITERATIONS = 1_000_000

  init_app_and_vm()

  let code = """
    (var i 0)
    (while (i < 1000000)
      (var s "hello")
      (i = (i + 1))
    )
    i
  """

  let compiled = compile(read_all(code))
  let ns = new_namespace("string_intern_bench")
  VM.frame.update(new_frame(ns))
  VM.cu = compiled

  let start = cpuTime()
  let result = VM.exec()
  let duration = cpuTime() - start

  let count = result.to_int()
  let iters_per_sec = float(count) / duration
  echo "String literal push benchmark"
  echo "Iterations: " & $count
  echo "Time:       " & $duration & "s"
  echo "Throughput: " & $int(iters_per_sec) & " iterations/sec"
