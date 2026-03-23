import unittest
import strutils
import std/tables
import ../helpers
import gene/types except Exception

test_vm """
  (gene/json/parse "{\"a\": true}")
""", proc(result: Value) =
  check result.kind == VkMap
  let key = "a".to_key()
  check map_data(result).hasKey(key)
  check map_data(result)[key].to_bool

test_vm """
  ([1 2].to_json)
""", "[1,2]"

test_vm """
  (gene/json/serialize `a)
""", "\"#GENE#a\""

test_vm """
  (gene/json/deserialize (gene/json/serialize `a))
""", "a".to_symbol_value()

test_vm """
  (gene/json/deserialize (gene/json/serialize "#GENE#a"))
""", "#GENE#a"

test_vm """
  (gene/json/serialize "#GENE#a")
""", proc(result: Value) =
  check result.kind == VkString
  check result.str.startsWith("\"#GENE#")
  check result.str.contains("\\\"#GENE#a\\\"")

test_vm """
  (gene/json/serialize 9007199254740993)
""", "\"#GENE#9007199254740993\""

test_vm """
  (gene/json/deserialize (gene/json/serialize 9007199254740993))
""", 9007199254740993'i64

test_vm """
  (gene/json/serialize `(f ^a 1 ^b 2 3 4))
""", "{\"genetype\":\"#GENE#f\",\"a\":1,\"b\":2,\"children\":[3,4]}"

test_vm """
  (gene/json/deserialize (gene/json/serialize `(f ^a 1 ^b 2 3 4)))
""", proc(result: Value) =
  check result.kind == VkGene
  check result.gene.type == "f".to_symbol_value()
  check result.gene.props["a".to_key()] == 1
  check result.gene.props["b".to_key()] == 2
  check result.gene.children.len == 2
  check result.gene.children[0] == 3
  check result.gene.children[1] == 4

test_vm """
  (gene/json/deserialize "{\"genetype\":\"#GENE#f\",\"a\":1}")
""", proc(result: Value) =
  check result.kind == VkGene
  check result.gene.type == "f".to_symbol_value()
  check result.gene.props["a".to_key()] == 1
  check result.gene.children.len == 0

test_vm """
  (gene/json/deserialize "{\"a\":1,\"b\":2}")
""", proc(result: Value) =
  check result.kind == VkMap
  check map_data(result)["a".to_key()] == 1
  check map_data(result)["b".to_key()] == 2

test_vm_error """
  (gene/json/deserialize "\"#GENE#1 2\"")
"""

test_vm_error """
  (gene/json/serialize {^genetype 1})
"""
