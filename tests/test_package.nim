import gene/types except Exception

import ./helpers

# How packaging work
#
# If a package will store one or more global reference, it should mention the names
# in package.gene.
# Package can specify whether multiple copies are allowed.
#   * By default, multiple copies are allowed
#   * If a package define/modify global variable, multiple copies are disallowed by
#     default, but can be overwritten. It'll cause undefined behaviour.
#
# Search order - can be changed to support Ruby gemset like feature.
#   * <APP DIR>/packages
#   * <USER HOME>/packages
#   * <RUNTIME DIR>/packages
#
# packages directory structure
# packages/
#   x/
#     1.0/
#     <GIT COMMIT>/
#

test_vm """
  $pkg/.name
""", "gene"

test_vm """
  ($dep "my_lib" ^path "tests/fixtures/pkg_my_lib")
  (import x from "index" ^pkg "my_lib")
  (x)
""", 1
