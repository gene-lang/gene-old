import os, unittest, strutils

import gene/types except Exception
import gene/vm

import ./helpers

# How module / import works:
# import a, b from "module"
# import from "module" a, b
# import a, b # will import from root's parent ns (which
#    could be the package ns or global ns or a intermediate ns)
# import from "module" a/[b c], d:my_d
# import a # will import from parent, and throw error if "a" not available, this can be useful to make sure the required resource is available when the module is initialized.
# path <=> code mappings can be defined so that we don't need to depend on the file system

test_vm """
  (import a from "tests/fixtures/mod1")
  a
""", 1

test_vm """
  (import a:aa from "tests/fixtures/mod1")
  aa
""", 1

test_vm """
  (import a b from "tests/fixtures/mod1")
  (a + b)
""", 3

test_vm """
  (import a b:bb from "tests/fixtures/mod1")
  (a + bb)
""", 3

test_vm """
  (import a:aa b:bb from "tests/fixtures/mod1")
  (aa + bb)
""", 3

test_vm """
  (import n from "tests/fixtures/mod1")
  (n/f 1)
""", 1

test_vm """
  (import n/f from "tests/fixtures/mod1")
  (f 1)
""", 1

test_vm """
  (import n/f:ff from "tests/fixtures/mod1")
  (ff 1)
""", 1

test_vm """
  (import n/[one two] from "tests/fixtures/mod1")
  (one + two)
""", 3

test_vm """
  (import n/[one:x two] from "tests/fixtures/mod1")
  (x + two)
""", 3

test_vm """
  (import n/[one:x two:y] from "tests/fixtures/mod1")
  (x + y)
""", 3

test_vm """
  (import value from "tests/fixtures/mod_if_main")
  value
""", 0

test_vm """
  (comptime
    (var target "mod1")
    (if (target == "mod1")
      (import a from "tests/fixtures/mod1")
    else
      (import b from "tests/fixtures/mod1")
    )
  )
  a
""", 1

test "Compilation & VM: comptime import uses $env":
  init_all()
  let previous = getEnv("GENE_TARGET", "")
  try:
    putEnv("GENE_TARGET", "mod1")
    let code = cleanup("""
      (comptime
        (var target ($env "GENE_TARGET"))
        (if (target == "mod1")
          (import a from "tests/fixtures/mod1")
        else
          (import b from "tests/fixtures/mod1")
        )
      )
      a
    """)
    check VM.exec(code, "test_code") == 1
  finally:
    if previous.len > 0:
      putEnv("GENE_TARGET", previous)
    else:
      delEnv("GENE_TARGET")

test "Compilation & VM: runtime import is rejected":
  init_all()
  let code = cleanup("""
    (var loader (fn []
      (import a from "tests/fixtures/mod1")
      a
    ))
    (loader)
  """)
  try:
    discard VM.exec(code, "test_code")
    fail()
  except CatchableError as e:
    check e.msg.contains("compile-time only")

test "Compilation & VM: explicit exports reject non-exported named imports":
  init_all()
  let code = cleanup("""
    (import hidden from "tests/fixtures/mod_exports")
    hidden
  """)
  try:
    discard VM.exec(code, "test_code")
    fail()
  except CatchableError as e:
    check e.msg.contains("AIR.IMPORT.EXPORT_MISSING")
    check e.msg.contains("hidden")

test "Compilation & VM: explicit exports limit wildcard imports":
  init_all()
  check VM.exec(cleanup("""
    (import * from "tests/fixtures/mod_exports")
    public
  """), "test_code") == 1

  check VM.exec(cleanup("""
    (import * from "tests/fixtures/mod_exports")
    hidden
  """), "test_code") == NIL

test "Compilation & VM: ambiguous module candidates fail with stable code":
  init_all()
  let code = cleanup("""
    (import value from "tests/fixtures/mod_ambiguous")
    (value)
  """)
  try:
    discard VM.exec(code, "test_code")
    fail()
  except CatchableError as e:
    check e.msg.contains("AIR.MODULE.AMBIGUOUS")
    check e.msg.contains("mod_ambiguous")

test "Compilation & VM: cyclic imports fail with stable code and chain":
  init_all()
  let code = cleanup("""
    (import a from "tests/fixtures/mod_cycle_a")
    (a)
  """)
  try:
    discard VM.exec(code, "test_code")
    fail()
  except CatchableError as e:
    check e.msg.contains("AIR.MODULE.CYCLE")
    check e.msg.contains("mod_cycle_a")
    check e.msg.contains("mod_cycle_b")

# test_vm """
#   (ns n
#     (fn f [] 1)
#   )
#   (import g from "tests/fixtures/mod2" ^inherit n)
#   (g)
# """, 1

# test_vm """
#   (import * from "tests/fixtures/mod_break")
#   (before_break)
#   (try
#     (after_break)
#     (fail "after_break should not be available")
#   catch *
#     # pass
#   )
# """, 1

# # test "Interpreter / eval: import":
# #   init_all()
# #   discard VM.import_module("file1", """
# #     (ns n
# #       (fn f [a] a)
# #     )
# #   """)
# #   var result = VM.eval """
# #     (import _ as x from "file1")  # Import root namespace
# #     x/f
# #   """
# #   check result.internal.fn.name == "f"

# # test "Interpreter / eval: import":
# #   init_all()
# #   var result = VM.eval """
# #     (import gene/Object)  # Import from parent namespace
# #     Object
# #   """
# #   check result.internal.class.name == "Object"

# test_import_matcher "(import a b from \"module\")", proc(r: ImportMatcherRoot) =
#   check r.from == "module"
#   check r.children.len == 2
#   check r.children[0].name == "a"
#   check r.children[1].name == "b"

# test_import_matcher "(import from \"module\" a b)", proc(r: ImportMatcherRoot) =
#   check r.from == "module"
#   check r.children.len == 2
#   check r.children[0].name == "a"
#   check r.children[1].name == "b"

# test_import_matcher "(import a b/[c d])", proc(r: ImportMatcherRoot) =
#   check r.children.len == 2
#   check r.children[0].name == "a"
#   check r.children[1].name == "b"
#   check r.children[1].children.len == 2
#   check r.children[1].children[0].name == "c"
#   check r.children[1].children[1].name == "d"

# test_import_matcher "(import a b/c)", proc(r: ImportMatcherRoot) =
#   check r.children.len == 2
#   check r.children[0].name == "a"
#   check r.children[1].name == "b"
#   check r.children[1].children.len == 1
#   check r.children[1].children[0].name == "c"

# # test_import_matcher "(import a: my_a b/c: my_c)", proc(r: ImportMatcherRoot) =
# #   check r.children.len == 2
# #   check r.children[0].name == "a"
# #   check r.children[0].as == "my_a"
# #   check r.children[1].name == "b"
# #   check r.children[1].children.len == 1
# #   check r.children[1].children[0].name == "c"
# #   check r.children[1].children[0].as == "my_c"

# # test_core """
# #   ($stop_inheritance)
# #   (try
# #     (assert true)  # assert is not inherited any more
# #     1
# #   catch *
# #     2
# #   )
# # """, 2
