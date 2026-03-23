import unittest

import gene/types except Exception

import ../helpers

suite "PubSub":
  test "genex/unsub detaches subscription":
    test_vm """
    (var seen [])
    (var subbed (genex/sub `tick (fn [] (seen .append "run"))))
    (genex/unsub subbed)
    (genex/pub `tick)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    seen
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 0

  test "subscription handle .unsub is equivalent":
    test_vm """
    (var count 0)
    (var subbed (genex/sub `tick (fn [] (count = (+ count 1)))))
    subbed/.unsub
    (genex/pub `tick)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    count
    """, 0

  test "double unsubscribe is a no-op":
    test_vm """
    (var count 0)
    (var subbed (genex/sub `tick (fn [] (count = (+ count 1)))))
    (genex/unsub subbed)
    (genex/unsub subbed)
    (genex/pub `tick)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    count
    """, 0

  test "payloadless events coalesce by default":
    test_vm """
    (var count 0)
    (genex/sub `tick (fn [] (count = (+ count 1))))
    (genex/pub `tick)
    (genex/pub `tick)
    (genex/pub `tick)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    count
    """, 1

  test "payloaded events stay distinct by default":
    test_vm """
    (var total 0)
    (genex/sub `tick (fn [payload]
      (total = (+ total payload/id))
    ))
    (genex/pub `tick {^id 1})
    (genex/pub `tick {^id 1})
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    total
    """, 2

  test "combine true merges equal payloaded events":
    test_vm """
    (var total 0)
    (genex/sub `tick (fn [payload]
      (total = (+ total payload/id))
    ))
    (genex/pub `tick {^id 2} ^combine true)
    (genex/pub `tick {^id 2} ^combine true)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    total
    """, 2

  test "publish during callback is deferred to a later poll":
    test_vm """
    (var order [])
    (genex/sub `a (fn []
      (order .append "a-start")
      (genex/pub `b)
      (gene/poll_event_loop)
      (order .append "a-end")
    ))
    (genex/sub `b (fn []
      (order .append "b")
    ))
    (genex/pub `a)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    (var j 0)
    (while (< j 200)
      (j = (+ j 1))
    )
    order
    """, proc(r: Value) =
      check r.kind == VkArray
      check array_data(r).len == 3
      check array_data(r)[0].str == "a-start"
      check array_data(r)[1].str == "a-end"
      check array_data(r)[2].str == "b"

  test "quoted complex symbols are valid event types":
    test_vm """
    (var count 0)
    (genex/sub `app/tasks/run (fn [] (count = (+ count 1))))
    (genex/pub `app/tasks/run)
    (var i 0)
    (while (< i 200)
      (i = (+ i 1))
    )
    count
    """, 1
