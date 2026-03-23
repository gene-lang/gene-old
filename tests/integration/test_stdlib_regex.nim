import unittest
import ../helpers
import gene/types except Exception

test_vm """
  (var m (#/a/ .match "a"))
  m/value
""", "a"

test_vm """
  (var r (new gene/Regexp ^^i "ab"))
  (var m (r .match "AB"))
  m/value
""", "AB"

test_vm """
  (var m (#/(a)(b)/ .process "ab"))
  m/captures/0
""", "a"

test_vm """
  (var m (#/(?<word>ab)/ .match "zabz"))
  m/named_captures/word
""", "ab"

test_vm """
  (var m (#/你/ .match "a你b"))
  [m/start m/end]
""", @[1, 2]

test_vm """
  (#/\\d/ .scan "a1b2")
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0].str == "1"
  check array_data(result)[1].str == "2"

test_vm """
  (#/(\\d)/[\\1]/ .replace_all "a1b2")
""", "a[1]b[2]"

test_vm """
  ("a1b2" .replace_all #/(\\d)/[\\1]/)
""", "a[1]b[2]"

test_vm """
  (#/(?<d>\\d)/ .gsub "a1b2" "[\\k<d>]")
""", "a[1]b[2]"

test_vm_error """
  ("ab" .match "a")
"""
