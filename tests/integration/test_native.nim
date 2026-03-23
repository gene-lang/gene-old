import gene/types except Exception

import ../helpers

# Native functions / methods

test_vm """
  (gene/test1)
""", 1

test_vm """
  (gene/test2 10 20)
""", 30

test_vm """
  (fn add_twice [x]
    (gene/test_increment (gene/test_increment x)))
  (gene/test_reentry add_twice 5)
""", 9
