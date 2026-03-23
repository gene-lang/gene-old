import unittest
import strutils
import json
import gene/types except Exception
import gene/vm

import ./helpers

suite "Source trace diagnostics":
  test "Compile error includes source location":
    init_all()
    let code = "(match 1)"
    try:
      discard VM.exec(code, "sample.gene")
      check false
    except types.Exception as e:
      let msg = e.msg
      check "sample.gene" in msg
      check ":1:" in msg
      check "match has been removed" in msg

  test "Destructuring assignment error includes source location":
    init_all()
    let code = "([a b] = [1 2])"
    try:
      discard VM.exec(code, "assign.gene")
      check false
    except types.Exception as e:
      let msg = e.msg
      check "assign.gene" in msg
      check ":1:" in msg
      check "destructuring assignment has been removed" in msg

  test "Runtime error includes source location":
    init_all()
    let code = "(do (throw \"boom\"))"
    try:
      discard VM.exec(code, "runtime.gene")
      check false
    except types.Exception as e:
      let msg = e.msg
      let diag = parseJson(msg)
      check diag["span"]["file"].getStr() == "runtime.gene"
      check diag["span"]["line"].getInt() == 1
      check diag["span"]["column"].getInt() == 5
      check "boom" in msg
