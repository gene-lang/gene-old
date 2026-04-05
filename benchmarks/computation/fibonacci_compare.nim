## Fibonacci benchmark: VM interpreter vs native compilation side-by-side.
## Runs fib(30) in both modes and prints a comparison table.

when isMainModule:
  import times, os, strformat

  import ../../src/gene/types
  import ../../src/gene/parser
  import ../../src/gene/compiler
  import ../../src/gene/vm

  var n = "30"
  let args = command_line_params()
  if args.len > 0:
    n = args[0]

  # ── VM interpreter path (untyped, native disabled) ──
  init_app_and_vm()
  VM.native_code = false

  let vm_code = fmt"""
    (fn fib [n]
      (if (< n 2)
        then n
        else (+ (fib (- n 1)) (fib (- n 2)))))
    (fib {n})
  """

  let vm_compiled = compile(read_all(vm_code))
  let vm_ns = new_namespace("fibonacci_vm")
  VM.frame.update(new_frame(vm_ns))
  VM.cu = vm_compiled
  VM.trace = false

  let vm_start = cpuTime()
  let vm_result = VM.exec()
  let vm_duration = cpuTime() - vm_start

  let vm_int_result =
    case vm_result.kind
    of VkInt: vm_result.to_int()
    of VkFloat: vm_result.to_float().int
    else: 0

  # ── Native compilation path (typed, native enabled) ──
  init_app_and_vm()
  VM.native_code = true

  let native_code = fmt"""
    (fn fib [n: Int] -> Int
      (if (<= n 1)
        n
      else
        (+ (fib (- n 1)) (fib (- n 2)))))
    (fib {n})
  """

  let native_compiled = compile(read_all(native_code))
  let native_ns = new_namespace("fibonacci_native")
  VM.frame.update(new_frame(native_ns))
  VM.cu = native_compiled
  VM.trace = false

  let native_start = cpuTime()
  let native_result = VM.exec()
  let native_duration = cpuTime() - native_start

  let native_int_result =
    case native_result.kind
    of VkInt: native_result.to_int()
    of VkFloat: native_result.to_float().int
    else: 0

  # ── Results ──
  echo fmt"=== Fibonacci({n}) Comparison ==="
  echo ""
  echo fmt"  VM interpreter:      {vm_duration:.6f}s  result={vm_int_result}"
  echo fmt"  Native compilation:  {native_duration:.6f}s  result={native_int_result}"
  echo ""
  if native_duration > 0:
    let speedup = vm_duration / native_duration
    echo fmt"  Speedup: {speedup:.2f}x"
  if vm_int_result != native_int_result:
    echo "  WARNING: results differ!"
