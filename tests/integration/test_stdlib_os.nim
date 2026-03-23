import osproc
import unittest

import ../helpers

test_vm """
  (gene/os/exec "pwd")
""", execCmdEx("pwd")[0]
