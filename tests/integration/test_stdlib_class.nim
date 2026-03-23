import gene/types except Exception

import ../helpers

test_vm """
  (gene/Class .name)
""", "Class"

test_vm """
  ((gene/Class .parent) .name)
""", "Object"

test_vm """
  ((gene/String .parent) .name)
""", "Object"

test_vm """
  (gene/Class is Class)
""", true.to_value()

test_vm """
  (gene/Object is Class)
""", true.to_value()

test_vm """
  (gene/Object is Object)
""", true.to_value()

test_vm """
  (var DynamicGreeter
    (Class
      ^name "DynamicGreeter"
      ^parent Object
      ^methods {
        ^greet (fn [] "hello from dynamic class")
      }
    )
  )
  ((new DynamicGreeter) .greet)
""", "hello from dynamic class"
