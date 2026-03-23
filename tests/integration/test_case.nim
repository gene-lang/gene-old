import gene/types except Exception

import ../helpers

# Basic case matching
test_vm """
  (case 1 when 1 "one" when 2 "two" else "other")
""", "one"

test_vm """
  (case 2 when 1 "one" when 2 "two" else "other")
""", "two"

test_vm """
  (case 3 when 1 "one" when 2 "two" else "other")
""", "other"

# Case without else returns nil
test_vm """
  (case 5 when 1 "one" when 2 "two")
""", NIL

# Variable target
test_vm """
  (var x 2)
  (case x when 1 "one" when 2 "two" else "other")
""", "two"

# Multi-expression body
test_vm """
  (case 2
    when 1
      (var x 10)
      x
    when 2
      (var y 20)
      y
    else 0
  )
""", 20

# String matching
test_vm """
  (case "hello" when "bye" "goodbye" when "hello" "hi" else "unknown")
""", "hi"

# Nested case
test_vm """
  (var x 1)
  (var y 2)
  (case x
    when 1
      (case y when 1 "x=1,y=1" when 2 "x=1,y=2" else "x=1,y=?")
    when 2 "x=2"
    else "x=?"
  )
""", "x=1,y=2"