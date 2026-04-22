import std/unittest

import gene/types except Exception
import gene/vm
import gene/vm/thread

proc expect_thread_surface_removed(code: string) =
  try:
    discard VM.exec(code, "legacy_thread_surface.gene")
    check false
  except CatchableError as e:
    discard e

suite "Legacy Thread-First Surface Removal":
  setup:
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()

  test "spawn is retired with an actor migration error":
    expect_thread_surface_removed("""
      (spawn (println "legacy"))
    """)

  test "spawn_return is retired with an actor migration error":
    expect_thread_surface_removed("""
      (spawn_return 1)
    """)

  test "top-level send_expect_reply is retired":
    expect_thread_surface_removed("""
      (send_expect_reply $main_thread 1)
    """)

  test "Thread methods are retired":
    expect_thread_surface_removed("""
      ($main_thread .send_expect_reply 41)
    """)

    expect_thread_surface_removed("""
      ($main_thread .on_message (fn [msg] msg))
    """)

  test "keep_alive is retired":
    expect_thread_surface_removed("""
      (keep_alive)
    """)
