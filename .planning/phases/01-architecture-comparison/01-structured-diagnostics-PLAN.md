---
phase: 01-architecture-comparison
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/gene/vm/diagnostics.nim
  - src/gene/vm/runtime_helpers.nim
  - src/gene/vm/exceptions.nim
  - src/gene/vm/exec.nim
  - tests/test_exception.nim
autonomous: true
requirements:
  - DIAG-01

must_haves:
  truths:
    - "Runtime errors produce a JSON envelope with 'code', 'severity', 'stage', 'span', and 'message' fields"
    - "The JSON envelope is emitted at the point where gene-old currently calls format_runtime_exception"
    - "Existing test_exception.nim tests continue to pass after the change"
    - "A new test asserts the structured fields are present in the error output"
    - "Source location (filename, line, column) is populated from SourceTrace when available"
  artifacts:
    - path: "src/gene/vm/diagnostics.nim"
      provides: "make_diagnostic_message, infer_diag_code helpers"
      exports: ["make_diagnostic_message", "infer_diag_code", "is_diagnostic_envelope"]
    - path: "src/gene/vm/runtime_helpers.nim"
      provides: "Updated format_runtime_exception that returns JSON envelope"
      contains: "make_diagnostic_message"
    - path: "tests/test_exception.nim"
      provides: "New test asserting JSON envelope structure"
      contains: "GENE.RUNTIME.ERROR"
  key_links:
    - from: "src/gene/vm/exceptions.nim"
      to: "src/gene/vm/diagnostics.nim"
      via: "format_runtime_exception calls make_diagnostic_message"
      pattern: "make_diagnostic_message"
    - from: "src/gene/vm/exec.nim"
      to: "src/gene/vm/diagnostics.nim"
      via: "format_runtime_exception calls make_diagnostic_message"
      pattern: "make_diagnostic_message"
---

<objective>
Add structured diagnostic error envelopes to gene-old's runtime, ported from gene's makeDiagnosticMessage pattern.

Purpose: Replace unstructured string exceptions with machine-parseable JSON so tooling, IDEs, and AI agents can extract error codes, source spans, and repair hints programmatically. This directly addresses the fragile REPL-on-error fallback documented in CONCERNS.md.

Output: New src/gene/vm/diagnostics.nim module; updated format_runtime_exception to emit JSON; new test asserting envelope shape.
</objective>

<execution_context>
@/Users/gcao/.claude/get-shit-done/workflows/execute-plan.md
@/Users/gcao/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@/Users/gcao/gene-workspace/gene-old/.planning/codebase/ARCHITECTURE.md
@/Users/gcao/gene-workspace/gene-old/.planning/codebase/CONCERNS.md

<interfaces>
<!-- Key types and patterns the executor needs. Extracted from codebase. -->

From src/gene/vm/runtime_helpers.nim (current format_runtime_exception):
```nim
proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string =
  let trace = self.current_trace()
  let location = trace_location(trace)
  var detail = $value
  ...
  if location.len > 0:
    "Gene exception at " & location & ": " & detail
  else:
    "Gene exception: " & detail
```

From src/gene/vm/runtime_helpers.nim (current_trace returns SourceTrace):
```nim
proc current_trace(self: ptr VirtualMachine): SourceTrace =
  if self.cu.is_nil: return nil
  if self.pc >= 0 and self.pc < self.cu.instruction_traces.len:
    let trace = self.cu.instruction_traces[self.pc]
    ...
  nil
```

SourceTrace fields (confirmed from src/gene/types/type_defs.nim):
- `filename`: string
- `line`: int
- `column`: int

From src/gene/vm/exceptions.nim (call sites that raise with format_runtime_exception):
```nim
raise new_exception(types.Exception, self.format_runtime_exception(exception_value))
```

Also used at:
- src/gene/vm/exec.nim line ~115 (unhandled exception in exec loop)
- src/gene/vm/exec.nim line ~4085, ~4156 (failed futures)

Reference implementation in gene/src/vm/core.nim (makeDiagnosticMessage):
```nim
proc makeDiagnosticMessage(
  code: string; message: string; stage = "runtime"; modulePath = "";
  hints: seq[string] = @[]; repairTags: seq[string] = @[];
  spanFile = ""; spanLine = 0; spanColumn = 0
): string =
  var root = newJObject()
  root["code"] = %code
  root["severity"] = %"error"
  root["stage"] = %stage
  root["module"] = %modulePath
  root["span"] = %*{"file": spanFile, "line": spanLine, "column": spanColumn}
  root["message"] = %message
  root["hints"] = newJArray()
  root["repair_tags"] = newJArray()
  $root
```
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create diagnostics.nim with make_diagnostic_message helper</name>
  <files>src/gene/vm/diagnostics.nim</files>
  <action>
Create a new file `src/gene/vm/diagnostics.nim` that provides structured error envelope helpers. This module is included from vm.nim (like the other vm/ subfiles) so it has access to the VirtualMachine pointer and SourceTrace types.

Implement the following procs:

1. `proc infer_diag_code(message: string): string`
   - Converts a plain error message to a dotted diagnostic code
   - Pattern: `"division by zero"` or `"divide"` -> `"GENE.ARITH.DIV_ZERO"`
   - Pattern: `"method not found"` or `"no method"` -> `"GENE.OOP.METHOD_NOT_FOUND"`
   - Pattern: `"undefined variable"` or `"not defined"` -> `"GENE.SCOPE.UNDEFINED_VAR"`
   - Pattern: `"stack overflow"` -> `"GENE.VM.STACK_OVERFLOW"`
   - Pattern: `"failed to load extension"` -> `"GENE.EXT.LOAD_FAILED"`
   - Default: `"GENE.RUNTIME.ERROR"`

2. `proc make_diagnostic_message(code, message: string; stage = "runtime"; file = ""; line = 0; column = 0; hints: seq[string] = @[]): string`
   - Builds a JSON object string using std/json (`newJObject`, `%`, `%*`)
   - Fields: `code`, `severity` (always `"error"`), `stage`, `span` (`{file, line, column}`), `message`, `hints` (array), `repair_tags` (array, always `["runtime"]`)
   - Returns `$root` (the JSON string)
   - Import: `import std/json` at top of file

3. `proc is_diagnostic_envelope(message: string): bool`
   - Returns true if message is already a JSON object string containing `"code"` and `"message"` keys
   - Used to avoid double-wrapping errors that are already structured

Note: gene-old uses Nim's `std/json`. Add `import std/json` at the top of diagnostics.nim. The file is included (not imported) via vm.nim's include chain, so it can reference VirtualMachine and SourceTrace directly.

SourceTrace fields are confirmed as `filename` (string), `line` (int), and `column` (int) — use these exact names.
  </action>
  <verify>nim c -r tests/test_exception.nim 2>&1 | tail -20</verify>
  <done>diagnostics.nim exists with make_diagnostic_message, infer_diag_code, and is_diagnostic_envelope procs; test_exception.nim compiles and passes (exercises diagnostics.nim transitively).</done>
</task>

<task type="auto">
  <name>Task 2: Wire diagnostics into format_runtime_exception and update tests</name>
  <files>
    src/gene/vm/runtime_helpers.nim
    src/gene/vm/exceptions.nim
    src/gene/vm/exec.nim
    tests/test_exception.nim
  </files>
  <action>
**Step 1: Include diagnostics.nim in the vm.nim include chain.**

Open `src/gene/vm.nim` and add `include ./vm/diagnostics` near the top of the include block (before `runtime_helpers` since runtime_helpers will call it). Verify the include order is correct by checking how other subfiles are included.

**Step 2: Update format_runtime_exception in src/gene/vm/runtime_helpers.nim.**

Replace the current implementation:
```nim
proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string =
  let trace = self.current_trace()
  let location = trace_location(trace)
  var detail = $value
  ...
  if location.len > 0:
    "Gene exception at " & location & ": " & detail
  else:
    "Gene exception: " & detail
```

With the new implementation that calls make_diagnostic_message:
```nim
proc format_runtime_exception(self: ptr VirtualMachine, value: Value): string =
  let trace = self.current_trace()
  var detail: string
  if value.kind == VkInstance:
    let exception_class_val = App.app.exception_class
    if exception_class_val.kind == VkClass and value.instance_class == exception_class_val.ref.class:
      if "message".to_key() in instance_props(value):
        let msg_val = instance_props(value)["message".to_key()]
        detail = if msg_val.kind == VkString: msg_val.str else: $msg_val
      else:
        detail = $value
    else:
      detail = $value
  else:
    detail = $value
  # Return structured JSON envelope instead of plain string
  # SourceTrace fields: filename (string), line (int), column (int)
  let (file, line, column) = if trace != nil: (trace.filename, trace.line, trace.column) else: ("", 0, 0)
  make_diagnostic_message(
    code = infer_diag_code(detail),
    message = detail,
    file = file,
    line = line,
    column = column
  )
```

**Step 3: Update tests/test_exception.nim.**

Add a new test at the bottom of the file that verifies the structured envelope shape:

```nim
import std/json

test "runtime exception produces structured diagnostic envelope":
  # A throw with no catch should produce a JSON envelope in the exception message
  # We capture it via the Nim exception's msg field
  try:
    test_vm """(throw "test diagnostic")"""
    fail()
  except types.Exception as e:
    let msg = e.msg
    check msg.len > 0
    # Envelope must be valid JSON with required fields
    let parsed = parseJson(msg)
    check parsed.hasKey("code")
    check parsed.hasKey("message")
    check parsed.hasKey("severity")
    check parsed["severity"].getStr() == "error"
    check parsed.hasKey("span")
    check parsed["span"].hasKey("line")
```

Check how `test_vm_error` is defined in `tests/helpers.nim` to understand whether catching `types.Exception` is the right approach or whether there's a helper that captures exception messages. Adjust the test pattern to match the existing test style in test_exception.nim.

**Step 4: Verify existing tests still pass.**

Run `nim c -r tests/test_exception.nim` from the gene-old directory to confirm no regressions.
  </action>
  <verify>nim c -r tests/test_exception.nim 2>&1 | tail -20</verify>
  <done>
    - `nim c -r tests/test_exception.nim` exits 0 with all tests passing including the new structured envelope test
    - The new test verifies JSON fields: code, message, severity, span
    - format_runtime_exception now returns make_diagnostic_message output (a JSON string)
  </done>
</task>

</tasks>

<verification>
Run from /Users/gcao/gene-workspace/gene-old:
1. `nim c -r tests/test_exception.nim` - All tests pass, new structured test passes
2. `nim c -r tests/test_basic.nim` - No regressions in basic VM behavior
3. `nim c -r tests/test_scope.nim` - No regressions in scope/exception interaction
4. Manual check: `./bin/gene eval '(throw "test")'` outputs a JSON envelope to stderr
</verification>

<success_criteria>
- diagnostics.nim exists with make_diagnostic_message, infer_diag_code, is_diagnostic_envelope
- format_runtime_exception returns JSON envelope string (not plain text)
- All test_exception.nim tests pass including the new structured envelope test
- No regressions in test_basic.nim, test_scope.nim
- Gene programs that catch exceptions with `catch *` still work correctly (the change only affects uncaught exceptions propagated to Nim)
</success_criteria>

<output>
After completion, create `/Users/gcao/gene-workspace/gene-old/.planning/phases/01-architecture-comparison/01-01-SUMMARY.md`
</output>
