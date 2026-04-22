import std/unittest

import gene/types except Exception
import gene/vm
import gene/vm/thread

proc exec_gene(code: string, trace_name: string): Value =
  VM.exec(code, trace_name)

suite "Actor runtime":
  setup:
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()

  test "gene/actor/spawn requires enable first":
    let blocked = exec_gene("""
      (do
        (var blocked false)
        (try
          (gene/actor/spawn
            (fn [ctx msg state]
              state))
          NIL
        catch *
          (blocked = true)
        )
        blocked)
    """, "actor_spawn_requires_enable.gene")

    check blocked == TRUE

  test "gene/actor bootstrap keeps actors working while thread-first entrypoints are retired":
    let actor_state = exec_gene("""
      (do
        (gene/actor/enable)
        (var counter
          (gene/actor/spawn
            ^state 0
            (fn [ctx msg state]
              (case msg/kind
              when "increment"
                (+ state 1)
              when "get"
                (ctx .reply state)
                state
              else
                state))))
        (counter .send {^kind "increment"})
        (counter .send {^kind "increment"})
        (await (counter .send_expect_reply {^kind "get"})))
    """, "actor_state_progression.gene")

    check actor_state.kind == VkInt
    check actor_state.int64 == 2

    try:
      discard exec_gene("""
        (spawn 1)
      """, "thread_spawn_retired.gene")
      check false
    except CatchableError:
      discard
