import unittest
import os

import gene/types except Exception
import gene/vm
from gene/extension/c_api import gene_nil

# Export symbols for dynamic loading on macOS.
{.passL: "-Wl,-export_dynamic".}

proc extension_base_path(): string =
  for base in @["c_extension", "tests/c_extension"]:
    when defined(macosx):
      if fileExists(base & ".dylib"):
        return base
    elif defined(linux):
      if fileExists(base & ".so"):
        return base
    else:
      if fileExists(base & ".dll"):
        return base
  "tests/c_extension"

proc extension_file_path(base: string): string =
  when defined(macosx):
    result = base & ".dylib"
  elif defined(linux):
    result = base & ".so"
  else:
    result = base & ".dll"

proc eval_with_import(ext_base: string, code: string): Value =
  VM.exec("""
    (import add multiply concat strlen is_even greet from """" & ext_base & """" ^^native)
    """ & "\n" & code, "test_c_extension")

suite "C Extension Support":
  setup:
    init_app_and_vm()
    init_stdlib()
    discard gene_nil() # Keep c_api linked into the host binary.

    let setup_ext_base = extension_base_path()
    let ext_file = extension_file_path(setup_ext_base)
    if not fileExists(ext_file):
      if fileExists("tests/Makefile.c_extension"):
        discard execShellCmd("cd tests && make -f Makefile.c_extension")
      elif fileExists("Makefile.c_extension"):
        discard execShellCmd("make -f Makefile.c_extension")

    let ext_ready = fileExists(ext_file)
    if not ext_ready:
      skip()

  test "C extension - add function":
    let ext_base = extension_base_path()
    check eval_with_import(ext_base, "(add 10 20)") == 30.to_value()

  test "C extension - multiply function":
    let ext_base = extension_base_path()
    check eval_with_import(ext_base, "(multiply 6 7)") == 42.to_value()

  test "C extension - concat function":
    let ext_base = extension_base_path()
    let result = eval_with_import(ext_base, """(concat "Hello, " "World!")""")
    check result.kind == VkString
    check result.str == "Hello, World!"

  test "C extension - strlen function":
    let ext_base = extension_base_path()
    check eval_with_import(ext_base, """(strlen "Hello")""") == 5.to_value()

  test "C extension - is_even function":
    let ext_base = extension_base_path()
    check eval_with_import(ext_base, "(is_even 4)") == TRUE
    check eval_with_import(ext_base, "(is_even 5)") == FALSE

  test "C extension - greet function":
    let ext_base = extension_base_path()
    let result = eval_with_import(ext_base, """(greet "Alice")""")
    check result.kind == VkString
    check result.str == "Hello, Alice!"
