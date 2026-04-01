import unittest
import strutils

import gene/types except Exception
import gene/vm

import ../helpers

suite "HashMap":
  test_vm """
    (do
      (var m {{1 "one" "two" 2 [1 2] "pair"}})
      [(m .get 1) (m .get "two") (m .get [1 2])]
    )
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result).len == 3
    check array_data(result)[0] == "one".to_value()
    check array_data(result)[1] == 2.to_value()
    check array_data(result)[2] == "pair".to_value()

  test_vm """
    (do
      (var m {{1 "one"}})
      (m .set 2 "two")
      [(m .has 2) (m .contains 2) (m .delete 1) (m .size)]
    )
  """, proc(result: Value) =
    check result.kind == VkArray
    check array_data(result)[0] == TRUE
    check array_data(result)[1] == TRUE
    check array_data(result)[2] == "one".to_value()
    check array_data(result)[3] == 1.to_value()

  test_vm """
    (do
      (var m {{1 "one" "two" 2}})
      [(m .keys) (m .values) (m .pairs)]
    )
  """, proc(result: Value) =
    let keys = array_data(result)[0]
    let values = array_data(result)[1]
    let pairs = array_data(result)[2]
    check keys.kind == VkArray
    check values.kind == VkArray
    check pairs.kind == VkArray
    check array_data(keys) == @[1.to_value(), "two".to_value()]
    check array_data(values) == @["one".to_value(), 2.to_value()]
    check array_data(pairs).len == 2
    check array_data(array_data(pairs)[0]) == @[1.to_value(), "one".to_value()]
    check array_data(array_data(pairs)[1]) == @["two".to_value(), 2.to_value()]

  test_vm """
    (do
      (var total 0)
      (for k v in {{1 10 2 20}}
        (total += (k + v))
      )
      total
    )
  """, 33

  test_vm """
    (do
      (class Key
        (ctor [id]
          (/id = id)
        )
        (method hash [] /id)
      )
      (var key (new Key 7))
      (var m {{key "seven"}})
      (m .get key)
    )
  """, "seven"

  test_vm """
    (do
      (class BadKey
        (ctor [id]
          (/id = id)
        )
        (method hash [] 1)
      )
      (var k1 (new BadKey 1))
      (var k2 (new BadKey 2))
      (var m {{k1 "one" k2 "two"}})
      [(m .get k1) (m .get k2) (m .size)]
    )
  """, proc(result: Value) =
    check array_data(result)[0] == "one".to_value()
    check array_data(result)[1] == "two".to_value()
    check array_data(result)[2] == 2.to_value()

  test_vm """
    ({{
      1 "one"
      "two" 2
    }} .to_s)
  """, "{{1 \"one\" \"two\" 2}}"

  test "odd literal entries fail during evaluation":
    init_all()
    try:
      discard VM.exec("{{1 \"one\" 2}}", "hash_map_odd_literal.gene")
      fail()
    except CatchableError as e:
      check e.msg.contains("alternating key/value entries")

  test "unhashable objects are rejected":
    init_all()
    try:
      discard VM.exec("""
        (do
          (class NoHash
            (ctor []
              nil
            )
          )
          (var key (new NoHash))
          {{key "value"}}
        )
      """, "hash_map_unhashable.gene")
      fail()
    except CatchableError as e:
      check e.msg.contains("not hashable for HashMap")

  test_vm """
    (do
      (var m {{[1 2] "pair" 1 "one"}})
      (m .delete 1)
      (m .get [1 2])
    )
  """, "pair"
