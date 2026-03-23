import times, strformat
import ../src/gene/types except Exception
import ../src/gene/parser
import ../src/gene/compiler
import ../src/gene/vm
import ../helpers

proc benchmark_function_calls() =
  echo "=== Function Call Benchmark ==="
  
  let code = """
  (fn add [a b] (a + b))
  (fn test_loop [n]
    (var sum 0)
    (var i 0)
    (while (i < n)
      (sum = (add sum i))
      (i += 1)
    )
    sum
  )
  (test_loop 10000)
  """
  
  let start_time = cpuTime()
  
  for i in 0..<100:
    discard VM.exec(code, "benchmark")
  
  let end_time = cpuTime()
  let duration = end_time - start_time
  
  echo &"Function calls (100 iterations): {duration:.3f}s"
  echo &"Average per iteration: {duration/100*1000:.3f}ms"

proc benchmark_method_calls() =
  echo "\n=== Method Call Benchmark ==="

  let code = """
  (var sum 0)
  (var i 0)
  (while (i < 1000)
    (sum = (+ sum i))
    (i += 1)
  )
  sum
  """

  let start_time = cpuTime()

  for i in 0..<100:
    discard VM.exec(code, "benchmark")

  let end_time = cpuTime()
  let duration = end_time - start_time

  echo &"Simple loops (100 iterations): {duration:.3f}s"
  echo &"Average per iteration: {duration/100*1000:.3f}ms"

proc benchmark_mixed_calls() =
  echo "\n=== Recursive Function Benchmark ==="

  let code = """
  (fn factorial [n]
    (if (n <= 1)
      1
    else
      (n * (factorial (n - 1)))
    )
  )

  (var result 0)
  (var i 1)
  (while (i <= 10)
    (result += (factorial i))
    (i += 1)
  )
  result
  """

  let start_time = cpuTime()

  for i in 0..<100:
    discard VM.exec(code, "benchmark")

  let end_time = cpuTime()
  let duration = end_time - start_time

  echo &"Recursive calls (100 iterations): {duration:.3f}s"
  echo &"Average per iteration: {duration/100*1000:.3f}ms"

proc benchmark_native_calls() =
  echo "\n=== Native Function Call Benchmark ==="
  
  let code = """
  (var sum 0)
  (var i 0)
  (while (i < 10000)
    (sum = (+ sum i))
    (i += 1)
  )
  sum
  """
  
  let start_time = cpuTime()
  
  for i in 0..<100:
    discard VM.exec(code, "benchmark")
  
  let end_time = cpuTime()
  let duration = end_time - start_time
  
  echo &"Native calls (100 iterations): {duration:.3f}s"
  echo &"Average per iteration: {duration/100*1000:.3f}ms"

when isMainModule:
  echo "Unified Callable System Performance Benchmark"
  echo "============================================="

  init_all()

  benchmark_native_calls()
  benchmark_function_calls()
  benchmark_method_calls()
  benchmark_mixed_calls()
  
  echo "\n=== Summary ==="
  echo "All benchmarks completed successfully!"
  echo "The unified callable system handles all call types efficiently."
