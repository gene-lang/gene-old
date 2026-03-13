import unittest
import std/tables
import ./helpers
import gene/types except Exception

proc map_size(v: Value): int =
  result = 0
  for _, _ in map_data(v):
    result.inc()

test_vm """
  ({^a 1 ^b 2} .size)
""", 2

test_vm """
  ({} .empty?)
""", true

test_vm """
  ({^a 1} .not_empty?)
""", true

test_vm """
  (fn toValue [k v] v)
  ({} .map toValue)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_size(result) == 0

test_vm """
  (fn toKey [k v] k)
  ({^a 1 ^b 2} .map toKey)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_size(result) == 2
  check map_data(result)["a".to_key()] == "a".to_value()
  check map_data(result)["b".to_key()] == "b".to_value()

test_vm """
  (fn toValue [k v] v)
  ({^a 1 ^b 2} .map toValue)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_size(result) == 2
  check map_data(result)["a".to_key()] == 1.to_value()
  check map_data(result)["b".to_key()] == 2.to_value()
