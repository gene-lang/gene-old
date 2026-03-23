import unittest
import std/times
import ../helpers
import gene/types except Exception

test_vm """
  ((gene/today) .year)
""", now().year

test_vm """
  ((gene/now) .year)
""", now().year
