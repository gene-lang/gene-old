import unicode
import unittest
import ../helpers
import gene/types except Exception

test_vm """
  (("" .class).name)
""", "String"

test_vm """
  ("abc" .size)
""", 3

test_vm """
  ("你从哪里来？" .size)
""", 6

test_vm """
  ("你" .bytesize)
""", 3

test_vm """
  ("a你" .byte_at 1)
""", 228

# test_vm """
#   ("你" .bytes)
# """, proc(result: Value) =
#   check result.kind == VkBytes
#   check result.size == 3
#   check result[0] == 228.to_value()
#   check result[1] == 189.to_value()
#   check result[2] == 160.to_value()

# test_vm """
#   ("a你b" .byteslice 1 3)
# """, proc(result: Value) =
#   check result.kind == VkBytes
#   check result.size == 3
#   check result[0] == 228.to_value()
#   check result[1] == 189.to_value()
#   check result[2] == 160.to_value()

test_vm """
  ("abc" .substr 1)
""", "bc"

test_vm """
  ("abc" .substr -1)
""", "c"

test_vm """
  ("abc" .substr -2 -1)
""", "bc"

test_vm """
  ("a你b" .substr 1 1)
""", "你"

test_vm """
  ("a:b:c" .split ":")
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 3
  check array_data(result)[0].str == "a"
  check array_data(result)[1].str == "b"
  check array_data(result)[2].str == "c"

test_vm """
  ("a:b:c" .split ":" 2)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  check array_data(result)[0].str == "a"
  check array_data(result)[1].str == "b:c"

test_vm """
  ("foo  bar\tbaz" .split #/\\s+/)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 3
  check array_data(result)[0].str == "foo"
  check array_data(result)[1].str == "bar"
  check array_data(result)[2].str == "baz"

test_vm """
  ("abc" .index "b")
""", 1

test_vm """
  ("abc" .index "x")
""", -1

test_vm """
  ("a你b你" .index "你")
""", 1

test_vm """
  ("a你b你" .index "你" 2)
""", 3

test_vm """
  ("a你b你" .index #/你/ 2)
""", 3

test_vm """
  ("aba" .rindex "a")
""", 2

test_vm """
  ("abc" .rindex "x")
""", -1

test_vm """
  ("a你b你" .rindex "你")
""", 3

test_vm """
  ("banana" .rindex "ana" 2)
""", 1

test_vm """
  ("a你b你" .rindex #/你/ 2)
""", 1

test_vm """
  ("  abc  " .trim)
""", "abc"

test_vm """
  ("  abc  " .lstrip)
""", "abc  "

test_vm """
  ("  abc  " .rstrip)
""", "  abc"

test_vm """
  ("abc" .empty?)
""", false

test_vm """
  ("abc" .not_empty?)
""", true

test_vm """
  ("" .not_empty?)
""", false

test_vm """
  ("abc" .start_with? "ab")
""", true

test_vm """
  ("abc" .end_with? "bc")
""", true

test_vm """
  ("a你b" .include? "你")
""", true

test_vm """
  ("a你b" .include? #/你/)
""", true

test_vm """
  ("ÄBC" .downcase)
""", "äbc"

test_vm """
  ("äBC" .capitalize)
""", "Äbc"

test_vm """
  ("a你b" .reverse)
""", "b你a"

test_vm """
  ("a你b" .chars)
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 3
  check array_data(result)[0] == 'a'.to_value()
  check array_data(result)[1] == "你".rune_at(0).to_value()
  check array_data(result)[2] == 'b'.to_value()

test_vm """
  ("a你" .each_byte)
""", @[97, 228, 189, 160]

test_vm """
  ("abc" .starts_with "ab")
""", true

test_vm """
  ("abc" .starts_with "bc")
""", false

test_vm """
  ("abc" .ends_with "ab")
""", false

test_vm """
  ("abc" .ends_with "bc")
""", true

test_vm """
  ("abc" .to_uppercase)
""", "ABC"

test_vm """
  ("ABC" .to_uppercase)
""", "ABC"

test_vm """
  ("abc" .to_lowercase)
""", "abc"

test_vm """
  ("ABC" .to_lowercase)
""", "abc"

test_vm """
  ("ÄBC" .to_lowercase)
""", "äbc"

test_vm """
  ("42" .to_i)
""", 42

test_vm """
  ("  -7  " .to_i)
""", -7

test_vm_error """
  ("abc" .to_i)
"""

test_vm """
  ("abc" .char_at 1)
""", 'b'

test_vm """
  ("你从哪里来？" .char_at 1)
""", "从".rune_at(0)

test_vm """
  ($ "a" "b" 1)
""", "ab1"

test_vm """
  (var b "c")
  (#Str "a" b)
""", "ac"

test_vm """
  (var b "c")
  #"a#{b}"
""", "ac"

test_vm """
  (var s "a")
  (s .append "b")
  (s .append "c")
  s
""", "abc"

test_vm """
  ("aabc" .replace "a" "A")
""", "Aabc"
