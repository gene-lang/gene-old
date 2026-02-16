import parseopt, os, strutils, strformat, algorithm, tables

import ../gene/types
import ../gene/vm
import ../gene/compiler
import ./base

const DEFAULT_COMMAND = "run-examples"
const COMMANDS = @[DEFAULT_COMMAND]

type
  Options = object
    help: bool
    file: string

  ExampleTarget = object
    name: string
    fn_value: Value

let short_no_val = {'h'}
let long_no_val = @["help"]

const HELP_TEXT = """
Usage: gene run-examples <file.gene>

Run all function examples declared with ^examples in a Gene source file.

Examples:
  gene run-examples examples/full.gene
"""

proc handle*(cmd: string, args: seq[string]): CommandResult

proc init*(manager: CommandManager) =
  manager.register(COMMANDS, handle)
  manager.add_help("run-examples <file>: run all ^examples in <file>")

proc parse_options(args: seq[string]): Options =
  if args.len == 0:
    return

  for kind, key, value in get_opt(args, short_no_val, long_no_val):
    case kind
    of cmdArgument:
      if result.file.len == 0:
        result.file = key
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        result.help = true
      else:
        discard
    of cmdEnd:
      discard

proc format_expected_throw_type(v: Value): string =
  if v.kind == VkClass and v.ref != nil and v.ref.class != nil and v.ref.class.name.len > 0:
    return v.ref.class.name
  $v

proc thrown_class_name(value: Value): string =
  if value == NIL:
    return "Exception"
  let cls = value.get_class()
  if cls != nil and cls.name.len > 0:
    return cls.name
  $value.kind

proc thrown_message(value: Value, fallback: string): string =
  if value == NIL:
    return fallback
  if value.kind == VkInstance:
    let message_key = "message".to_key()
    if instance_props(value).hasKey(message_key):
      let msg = instance_props(value)[message_key]
      if msg.kind == VkString:
        return msg.str
      return $msg
  if value.kind == VkString:
    return value.str
  let rendered = $value
  if rendered.len > 0 and rendered != "nil":
    return rendered
  fallback

proc format_throw_outcome(value: Value, fallback: string): string =
  let cls = thrown_class_name(value)
  let msg = thrown_message(value, fallback)
  if msg.len > 0:
    return "throws " & cls & ": " & msg
  "throws " & cls

proc class_matches(value: Value, expected_class_value: Value): bool =
  if expected_class_value.kind != VkClass or expected_class_value.ref == nil or expected_class_value.ref.class == nil:
    return false
  var actual = value.get_class()
  let expected = expected_class_value.ref.class
  while actual != nil:
    if actual == expected:
      return true
    actual = actual.parent
  false

proc eval_example_expr(vm: ptr VirtualMachine, ns: Namespace, expr: Value): Value =
  if expr.is_literal:
    return expr

  let matcher = new_arg_matcher()
  let eval_fn = new_fn("__examples_eval__", matcher, @[expr])
  eval_fn.ns = ns
  eval_fn.scope_tracker = new_scope_tracker()
  eval_fn.parent_scope = nil
  eval_fn.compile()

  let fn_ref = new_ref(VkFunction)
  fn_ref.fn = eval_fn
  vm.exec_callable(fn_ref.to_ref_value(), @[])

proc add_target(targets: var seq[ExampleTarget], seen: var Table[uint64, bool],
                name_hint: string, fn_value: Value) =
  let identity = fn_value.raw
  if seen.hasKey(identity):
    return
  seen[identity] = true

  var name = name_hint
  if fn_value.kind == VkFunction and fn_value.ref != nil and fn_value.ref.fn != nil:
    let fn_name = fn_value.ref.fn.name
    if fn_name.len > 0 and fn_name != "<unnamed>":
      name = fn_name
  if name.len == 0:
    name = "<unnamed>"
  targets.add(ExampleTarget(name: name, fn_value: fn_value))

proc discover_targets(ns: Namespace, root_scope: Scope): seq[ExampleTarget] =
  var seen = initTable[uint64, bool]()

  if ns != nil:
    for key, value in ns.members:
      if value.kind != VkFunction or value.ref == nil or value.ref.fn == nil:
        continue
      if value.ref.fn.examples.len == 0:
        continue
      add_target(result, seen, get_symbol_gcsafe(key.symbol_index), value)

  var scope = root_scope
  while scope != nil:
    var index_to_name = initTable[int, string]()
    if scope.tracker != nil:
      for key, local_idx in scope.tracker.mappings:
        index_to_name[local_idx.int] = get_symbol_gcsafe(key.symbol_index)
    for i, value in scope.members:
      if value.kind != VkFunction or value.ref == nil or value.ref.fn == nil:
        continue
      if value.ref.fn.examples.len == 0:
        continue
      add_target(result, seen, index_to_name.getOrDefault(i, ""), value)
    scope = scope.parent

proc handle*(cmd: string, args: seq[string]): CommandResult =
  let options = parse_options(args)
  if options.help:
    return success(HELP_TEXT.strip())

  if options.file.len == 0:
    return failure("Missing file path. Usage: gene run-examples <file.gene>")

  if not fileExists(options.file):
    return failure("File not found: " & options.file)

  let file = absolutePath(options.file)

  init_app_and_vm()
  VM.type_check = true
  VM.contracts_enabled = true
  init_stdlib()
  set_program_args(file, @[])

  try:
    discard VM.exec(readFile(file), file)
  except CatchableError as e:
    return failure("Failed to load/compile examples file: " & e.msg)

  if VM == nil or VM.frame == nil or VM.frame.ns == nil:
    return failure("Failed to initialize module namespace for " & file)

  let module_ns = VM.frame.ns
  var targets = discover_targets(module_ns, VM.frame.scope)
  sort(targets, proc(a, b: ExampleTarget): int = cmp(a.name, b.name))

  if targets.len == 0:
    echo "No examples found in " & file
    return success()

  var total = 0
  var passed = 0
  var failed = 0

  for target in targets:
    let fn_obj = target.fn_value.ref.fn
    for idx, example in fn_obj.examples:
      total.inc()

      let example_source =
        if example.source.len > 0: example.source
        else:
          "<example>"
      let location =
        if example.trace != nil: trace_location(example.trace)
        else: file

      var expected_text = ""
      var actual_text = ""
      var case_passed = false
      var spec_error = ""

      var call_args: seq[Value] = @[]
      for arg_expr in example.args:
        try:
          call_args.add(eval_example_expr(VM, module_ns, arg_expr))
        except CatchableError as e:
          spec_error = "failed to evaluate argument expression: " & e.msg
          break

      var expected_value = NIL
      if spec_error.len == 0:
        case example.expectation_kind
        of FekReturn:
          try:
            expected_value = eval_example_expr(VM, module_ns, example.expected)
          except CatchableError as e:
            spec_error = "failed to evaluate expected result expression: " & e.msg
          expected_text = if spec_error.len == 0: "return " & $expected_value else: "return <invalid>"
        of FekAnyReturn:
          expected_text = "any return"
        of FekThrows:
          try:
            if example.expected.kind == VkSymbol and example.expected.str == "Exception":
              expected_value = App.app.exception_class
            else:
              expected_value = eval_example_expr(VM, module_ns, example.expected)
          except CatchableError as e:
            spec_error = "failed to evaluate expected exception type: " & e.msg
          if spec_error.len == 0 and expected_value.kind != VkClass:
            spec_error = "throws expectation must evaluate to a class, got " & $expected_value.kind
          expected_text =
            if spec_error.len == 0: "throws " & format_expected_throw_type(expected_value)
            else: "throws <invalid>"

      if spec_error.len > 0:
        actual_text = "spec error: " & spec_error
      else:
        VM.current_exception = NIL
        var returned_value = NIL
        var threw = false
        var thrown_value = NIL
        var thrown_error = ""

        try:
          returned_value = VM.exec_callable(target.fn_value, call_args)
        except CatchableError as e:
          threw = true
          thrown_error = e.msg
          thrown_value = VM.current_exception

        case example.expectation_kind
        of FekReturn:
          if threw:
            actual_text = format_throw_outcome(thrown_value, thrown_error)
            case_passed = false
          else:
            actual_text = "return " & $returned_value
            case_passed = returned_value == expected_value
        of FekAnyReturn:
          if threw:
            actual_text = format_throw_outcome(thrown_value, thrown_error)
            case_passed = false
          else:
            actual_text = "return " & $returned_value
            case_passed = true
        of FekThrows:
          if threw:
            actual_text = format_throw_outcome(thrown_value, thrown_error)
            case_passed = class_matches(thrown_value, expected_value)
          else:
            actual_text = "return " & $returned_value
            case_passed = false

        VM.current_exception = NIL

      if case_passed:
        passed.inc()
        echo fmt"PASS {target.name} example {idx + 1}: {example_source}"
      else:
        failed.inc()
        echo fmt"FAIL {target.name} example {idx + 1}: {example_source}"
        echo "  expected: " & expected_text
        echo "  actual: " & actual_text
        echo "  location: " & location

  echo fmt"Examples run: {total}, passed: {passed}, failed: {failed}, functions: {targets.len}"

  if failed > 0:
    return failure("")
  success()
