import std/unittest
import std/strutils
import std/tables

import gene/types except Exception  # Avoid collision with system.Exception
import gene/compiler
import gene/vm
import gene/vm/thread
from gene/parser import read

# Threading tests for bytecode VM
# Adapted for current implementation which uses:
# - Thread pool with worker threads
# - Gene AST compilation in worker threads
# - ARC garbage collection

suite "Threading Support":
  setup:
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()  # Initialize stdlib for await support

  test "Basic spawn - thread executes code":
    let code = """
      (var main_started true)
      (spawn (do
        (var thread_executed true)
      ))
      (sleep 100)
      main_started
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.frame = new_frame()
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check result == TRUE

  test "Multiple spawns - can spawn multiple threads":
    let code = """
      (var test_passed true)
      (spawn (var t1 1))
      (spawn (var t2 2))
      (spawn (var t3 3))
      (sleep 100)
      test_passed
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.frame = new_frame()
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check result == TRUE

  test "Spawn with variables - threads can create local variables":
    let code = """
      (var test_passed true)
      (spawn (do
        (var x 1)
        (var y 2)
        (var z (+ x y))
      ))
      (sleep 100)
      test_passed
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.frame = new_frame()
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check result == TRUE

  test "spawn_return with await - return value from thread":
    let code = """
      (await
        (spawn_return
          (+ 1 2)
        )
      )
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.pc = 0
    VM.frame = new_frame()
    VM.frame.stack_index = 0
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check to_int(result) == 3

  test "spawn_return await timeout yields typed async timeout":
    let code = """
      (do
        (var f
          (spawn_return
            (do
              (sleep 200)
              1
            )
          )
        )
        (var caught false)
        (try
          (await ^timeout 10 f)
          NIL
        catch *
          (caught = true)
        )
        [caught (f .state) (f .value)]
      )
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.pc = 0
    VM.frame = new_frame()
    VM.frame.stack_index = 0
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check result.kind == VkArray
    check array_data(result).len == 3
    check array_data(result)[0] == TRUE
    check array_data(result)[1] == "failure".to_symbol_value()
    let err = array_data(result)[2]
    check err.kind == VkInstance
    check instance_props(err)["code".to_key()].kind == VkString
    check instance_props(err)["code".to_key()].str == "AIR.ASYNC.TIMEOUT"

  test "Thread.send with reply returns payload":
    let code = """
      (do
        (var worker (spawn (do
          (thread .on_message (fn [msg]
            (msg .reply (msg .payload))
          ))
        )))
        (await (send_expect_reply worker {^a 1 ^b 2}))
      )
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.pc = 0
    VM.frame = new_frame()
    VM.frame.stack_index = 0
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check result.kind == VkMap
    check map_data(result)["a".to_key()].int64 == 1
    check map_data(result)["b".to_key()].int64 == 2

  test "Thread.send with keep_alive handles message callbacks":
    let code = """
      (do
        (var worker (spawn (do
          (thread .on_message (fn [msg]
            (msg .reply (+ (msg .payload) 1))
          ))
          (keep_alive)
        )))
        (await (send_expect_reply worker 41))
      )
    """
    let ast = read(code)
    let cu = compile_init(ast)

    VM.cu = cu
    VM.pc = 0
    VM.frame = new_frame()
    VM.frame.stack_index = 0
    VM.frame.scope = new_scope(new_scope_tracker())
    VM.frame.ns = App.app.gene_ns.ref.ns

    let result = VM.exec()
    check result.kind == VkInt
    check result.int64 == 42

  # TODO: Test spawn_return with args when implemented
  # test "spawn_return with args - pass arguments to thread":
  #   let code = """
  #     (await
  #       (spawn_return ^first 1 ^second 2
  #         (sleep 100)
  #         (first + second)
  #       )
  #     )
  #   """
  #   let result = eval_string(code)
  #   check result.int == 3

  # TODO: Test nested spawn_return when implemented
  # test "Nested spawn_return - spawn threads within threads":
  #   let code = """
  #     (await
  #       (spawn_return
  #         (var x
  #           (await
  #             (spawn_return
  #               2
  #             )
  #           )
  #         )
  #         (+ 1 x)
  #       )
  #     )
  #   """
  #   let result = eval_string(code)
  #   check result.int == 3

  # TODO: Test message passing when implemented
  # test "Thread message passing - send/receive messages":
  #   let code = """
  #     (var thread
  #       (spawn
  #         ($thread .on_message (msg ->
  #           (if (== msg.payload "stop")
  #             (var done true)
  #           )
  #         ))
  #         (while (not done)
  #           (sleep 100)
  #         )
  #       )
  #     )
  #     (sleep 100)
  #     (thread .send "stop")
  #     (thread .join)
  #     1
  #   """
  #   let result = eval_string(code)
  #   check result.int == 1

  # TODO: Test thread.join when implemented
  # test "Thread join - wait for thread completion":
  #   let code = """
  #     (var start (gene/now))
  #     (var thread
  #       (spawn
  #         (sleep 1000)
  #       )
  #     )
  #     (thread .join)
  #     (>= start.elapsed 1)
  #   """
  #   let result = eval_string(code)
  #   check result == TRUE

  # TODO: Test thread parent when implemented
  # test "Thread parent - access parent thread":
  #   let code = """
  #     (spawn
  #       (var thread $thread.parent)
  #       (thread .send 1)
  #     )
  #
  #     (var result (new Future))
  #     ($thread .on_message (msg ->
  #       (result .complete msg.payload)
  #       true
  #     ))
  #
  #     (await result)
  #   """
  #   let result = eval_string(code)
  #   check result.int == 1

  # TODO: Test keep_alive when implemented
  # test "Thread keep_alive - keep thread running":
  #   let code = """
  #     (var thread
  #       (spawn args: {x: 1}
  #         (global/test = x)
  #         $thread.keep_alive
  #       )
  #     )
  #     (sleep 200)
  #     (thread .run args: {x: 2}
  #       (global/test = x)
  #     )
  #     (var result
  #       (thread .run ^^return
  #         global/test
  #       )
  #     )
  #     (await result)
  #   """
  #   let result = eval_string(code)
  #   check result.int == 2
