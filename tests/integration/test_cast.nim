import gene/types except Exception

import ../helpers

# Cast an object of one type to another, with optional behavior overwriting
# Typical use: (cast (new A) B ...)

# TODO: cast is not implemented in the VM yet
# test_vm """
#   (class A
#     (method test _
#       1
#     )
#   )
#   (class B
#     (method test _
#       2
#     )
#   )
#   ((cast (new A) B).test)
# """, 2
