import unicode
import tables
import unittest

import gene/types except Exception

test "Value kind":
  check NIL.kind == VkNil
  check VOID.kind == VkVoid
  check PLACEHOLDER.kind == VkPlaceholder

  check TRUE.kind == VkBool
  check FALSE.kind == VkBool

  check 0.to_value().kind == VkInt

  var a = 1
  check a.addr.to_value().kind == VkPointer

  check 'a'.to_value().kind == VkChar
  check  "你".rune_at(0).to_value().kind == VkChar

  check "".to_value().kind == VkString
  check "a".to_value().kind == VkString
  check "ab".to_value().kind == VkString
  check "abc".to_value().kind == VkString
  check "abcd".to_value().kind == VkString
  check "abcde".to_value().kind == VkString
  check "abcdef".to_value().kind == VkString
  check "abcdefghij".to_value().kind == VkString
  check "你".to_value().kind == VkString
  check "你从哪里来？".to_value().kind == VkString

  check new_array_value().kind == VkArray
  check new_map_value().kind == VkMap
  check new_gene_value().kind == VkGene

  check "".to_symbol_value().kind == VkSymbol
  check "a".to_symbol_value().kind == VkSymbol
  check "abcdefghij".to_symbol_value().kind == VkSymbol
  check "你".to_symbol_value().kind == VkSymbol
  check "你从哪里来？".to_symbol_value().kind == VkSymbol

test "Value conversion":
  check nil.pointer.to_value().is_nil() == true
  check nil.pointer.to_value() == NIL

  check true.to_value().to_bool() == true
  check false.to_value().to_bool() == false
  check NIL.to_bool() == false
  check 0.to_value().to_bool() == true

  check 1.to_value().to_int() == 1
  # This test was for the old tagging system, skip for now
  check 1.1.to_value().to_float() == 1.1
  var a = 1
  check cast[ptr int64](a.addr.to_value().to_pointer())[] == 1

  check "".to_value().str() == ""
  check "a".to_value().str() == "a"
  check "ab".to_value().str() == "ab"
  check "abc".to_value().str() == "abc"
  check "abcd".to_value().str() == "abcd"
  check "abcde".to_value().str() == "abcde"
  check "abcdef".to_value().str() == "abcdef"
  check "abcdefghij".to_value().str() == "abcdefghij"
  check "你".to_value().str() == "你"
  check "你从哪里来？".to_value().str() == "你从哪里来？"

  check "".to_symbol_value().str() == ""
  check "abc".to_symbol_value().str() == "abc"
  check "abcdefghij".to_symbol_value().str() == "abcdefghij"
  check "你".to_symbol_value().str() == "你"
  check "你从哪里来？".to_symbol_value().str() == "你从哪里来？"

test "String / char":
  check "abc".to_value()[0] == 'a'.to_value()
  check "你".to_value()[0] == "你".rune_at(0)
  check "你从哪里来？".to_value()[0] == "你".rune_at(0)
  check "你从哪里来？".to_value()[1] == "从".rune_at(0)
  check "你".to_value().size == 1

test "Array":
  check new_array_value().size == 0
  check new_array_value(1).size == 1

  let a = new_array_value(1)
  check a[0] == 1
  check a[1] == NIL

test "Set display is unsupported":
  let s = new_set_value()
  check s.kind == VkSet
  check s.str_no_quotes() == "unsupported"
  check $s == "unsupported"

test "Frozen gene display":
  var gene_ptr = new_frozen_gene(1.to_value())
  gene_ptr[].props["a".to_key()] = 2.to_value()
  gene_ptr[].children.add(3.to_value())
  let g = gene_ptr.to_gene_value()
  check g.str_no_quotes() == "#(1 ^a 2 3)"
  check $g == "#(1 ^a 2 3)"
