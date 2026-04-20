import std/[os, times, unittest]

import gene/types except Exception
import gene/vm
import gene/vm/thread

proc exec_gene(code: string, trace_name: string): Value =
  VM.exec(code, trace_name)

proc await_vm_future(future_value: Value, timeout_ms = 2_000): Value =
  let deadline = epochTime() + (timeout_ms.float / 1000.0)
  let future = future_value.ref.future
  while future.state == FsPending and epochTime() < deadline:
    VM.event_loop_counter = 100
    VM.poll_event_loop()
    sleep(10)

  check future.state != FsPending
  check future.state == FsSuccess
  future.value

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

  test "gene/actor bootstrap keeps actor and thread surfaces separate":
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

    let thread_future = exec_gene("""
      (do
        (var worker
          (spawn
            (do
              (thread .on_message
                (fn [msg]
                  (msg .reply (+ (msg .payload) 1))))
              (keep_alive))))
        (worker .send_expect_reply 41))
    """, "thread_spawn_compatibility.gene")

    let thread_result = await_vm_future(thread_future)

    check thread_result.kind == VkInt
    check thread_result.int64 == 42
