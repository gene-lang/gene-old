import unittest
import tables
import ./helpers
import gene/types except Exception

test_vm """
  (var g `(1 ^a 2 3 4))
  (g .type)
""", 1.to_value()

test_vm """
  (var g `(1 ^a 2 3 4))
  (g .props)
""", proc(result: Value) =
  check result.kind == VkMap
  check map_data(result).len == 1
  check map_data(result)["a".to_key()] == 2.to_value()

test_vm """
(var g `(1 ^a 2 3 4))
(g .children)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0] == 3.to_value()
  check array_data(result)[1] == 4.to_value()
