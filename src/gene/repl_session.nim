import strutils, terminal, streams

import ./types
import ./compiler
import ./vm
import ./parser

proc exec_repl_compiled(vm: ptr VirtualMachine, compiled: CompilationUnit, scope: Scope, ns: Namespace,
                        caller_frame: Frame, caller_cu: CompilationUnit, caller_pc: int,
                        repl_frame: var Frame): Value =
  if caller_frame.isNil:
    if repl_frame.isNil:
      repl_frame = new_frame(ns)
    repl_frame.kind = FkFunction
    repl_frame.scope = scope
    repl_frame.ns = ns
  repl_frame.stack_index = 0
  repl_frame.call_bases.reset()
  repl_frame.collection_bases.reset()
  vm.frame = repl_frame
  vm.cu = compiled
  return vm.exec()

proc is_throw_form(input: string, filename: string): bool =
  var parser = new_parser()
  var stream = new_string_stream(input)
  parser.open(stream, filename)
  defer: parser.close()

  var first: Value = NIL
  try:
    while true:
      let node = parser.read()
      if node == PARSER_IGNORE:
        continue
      first = node
      break
  except ParseEofError:
    return false
  except ParseError:
    return false

  if first.kind != VkGene or first.gene.type != "throw".to_symbol_value():
    return false

  try:
    while true:
      let node = parser.read()
      if node == PARSER_IGNORE:
        continue
      return false
  except ParseEofError:
    return true
  except ParseError:
    return false

proc run_repl_session*(vm: ptr VirtualMachine, scope_tracker: ScopeTracker, scope: Scope, ns: Namespace,
                       filename = "<repl>", prompt = "gene> ", show_banner = true,
                       caller_frame: Frame = nil, caller_cu: CompilationUnit = nil, caller_pc: int = 0,
                       print_results = true, propagate_exceptions = false): Value =
  if vm.isNil:
    return NIL

  if scope_tracker.isNil or scope.isNil or ns.isNil:
    not_allowed("run_repl_session requires scope tracker, scope, and namespace")

  scope_tracker.scope_started = true
  let return_cu = if not caller_cu.isNil: caller_cu else: vm.cu
  let saved_repl_active = vm.repl_active
  let saved_repl_on_error = vm.repl_on_error
  vm.repl_active = true
  vm.repl_on_error = false
  defer:
    vm.repl_active = saved_repl_active
    vm.repl_on_error = saved_repl_on_error

  if show_banner:
    echo "Gene REPL - Interactive Gene Language Shell"
    echo "Type 'exit' or 'quit' to exit, 'help' for help"
    echo ""

  var last_value = NIL
  var repl_frame: Frame = nil

  var input_file = stdin
  var close_input = false
  if stdin.isatty():
    var tty: File
    if open(tty, "/dev/tty", fmRead):
      input_file = tty
      close_input = true

  defer:
    if close_input:
      input_file.close()

  while true:
    stdout.write(prompt)
    stdout.flushFile()

    var input: string
    if not input_file.readLine(input):
      if prompt.len > 0:
        echo ""
      break

    let trimmed = input.strip()
    if trimmed.len == 0:
      continue

    if trimmed == "exit" or trimmed == "quit":
      break

    if trimmed == "help":
      echo "Gene REPL Help:"
      echo "  exit, quit: Exit the REPL"
      echo "  help: Show this help message"
      echo "  Any other input is evaluated as Gene code"
      continue

    let propagate_this = propagate_exceptions and is_throw_form(trimmed, filename)

    try:
      let compiled = parse_and_compile_repl(trimmed, filename, scope_tracker)
      let value = exec_repl_compiled(vm, compiled, scope, ns, caller_frame, return_cu, caller_pc, repl_frame)
      last_value = value
      if print_results:
        if not value.is_nil() and value.kind != VkVoid and
           not trimmed.starts_with("(print") and not trimmed.starts_with("(println"):
          echo $value
    except CatchableError as e:
      if propagate_this and vm.current_exception != NIL:
        raise
      echo "Error: ", e.msg
      vm.current_exception = NIL

  return last_value

proc run_repl_script*(vm: ptr VirtualMachine, inputs: seq[string], scope_tracker: ScopeTracker, scope: Scope,
                      ns: Namespace, filename = "<repl>", caller_frame: Frame = nil,
                      caller_cu: CompilationUnit = nil, caller_pc: int = 0): Value =
  ## Scripted REPL execution for tests or non-interactive sessions.
  if vm.isNil:
    return NIL

  if scope_tracker.isNil or scope.isNil or ns.isNil:
    not_allowed("run_repl_script requires scope tracker, scope, and namespace")

  scope_tracker.scope_started = true
  let return_cu = if not caller_cu.isNil: caller_cu else: vm.cu

  var last_value = NIL
  var repl_frame: Frame = nil

  for input in inputs:
    let trimmed = input.strip()
    if trimmed.len == 0:
      continue
    if trimmed == "exit" or trimmed == "quit":
      break
    if trimmed == "help":
      continue

    let compiled = parse_and_compile_repl(trimmed, filename, scope_tracker)
    last_value = exec_repl_compiled(vm, compiled, scope, ns, caller_frame, return_cu, caller_pc, repl_frame)

  return last_value

proc run_repl_on_error*(vm: ptr VirtualMachine, exception_value: Value, prompt = "gene> "): Value =
  ## Start a REPL session using the current frame scope and expose $ex.
  if vm.isNil or exception_value == NIL or vm.frame.isNil:
    return NIL

  let parent_scope = vm.frame.scope
  let parent_tracker = if parent_scope != nil: parent_scope.tracker else: nil
  let scope_tracker = new_scope_tracker(parent_tracker)
  let scope = new_scope(scope_tracker, parent_scope)
  let ns = if vm.frame.ns != nil:
    vm.frame.ns
  else:
    new_namespace(App.app.global_ns.ref.ns, "repl")

  let saved_frame = vm.frame
  let saved_cu = vm.cu
  let saved_pc = vm.pc
  let saved_exception = vm.current_exception
  let saved_repl_exception = vm.repl_exception
  let saved_repl_active = vm.repl_active
  let saved_repl_on_error = vm.repl_on_error
  let saved_exception_handlers = vm.exception_handlers

  vm.repl_active = true
  vm.repl_on_error = false
  vm.exception_handlers = @[]
  vm.repl_exception = exception_value
  vm.current_exception = NIL

  var repl_value = NIL
  var thrown_exception = NIL
  try:
    repl_value = run_repl_session(vm, scope_tracker, scope, ns, "<repl>", prompt, true,
                                  nil, nil, 0, true, true)  # propagate_exceptions = true
  except CatchableError:
    # Capture exception thrown from REPL so we can restore it after cleanup
    thrown_exception = vm.current_exception

  vm.current_exception = saved_exception
  vm.repl_exception = saved_repl_exception
  vm.exception_handlers = saved_exception_handlers
  vm.repl_active = saved_repl_active
  vm.repl_on_error = saved_repl_on_error
  vm.frame = saved_frame
  vm.cu = saved_cu
  vm.pc = saved_pc
  scope.free()

  # If an exception was thrown from the REPL, restore it so caller can handle it
  if thrown_exception != NIL:
    vm.current_exception = thrown_exception

  return repl_value

proc run_repl_on_throw*(vm: ptr VirtualMachine, exception_value: Value): Value =
  ## Start a REPL session at the throw site; return a thrown exception or NIL.
  if vm.isNil or vm.frame.isNil:
    return NIL
  if not stdin.isatty():
    return exception_value

  let parent_scope = vm.frame.scope
  let parent_tracker = if parent_scope != nil: parent_scope.tracker else: nil
  let scope_tracker = new_scope_tracker(parent_tracker)
  let scope = new_scope(scope_tracker, parent_scope)
  let ns = if vm.frame.ns != nil:
    vm.frame.ns
  else:
    new_namespace(App.app.global_ns.ref.ns, "repl")

  let saved_frame = vm.frame
  let saved_cu = vm.cu
  let saved_pc = vm.pc
  let saved_exception = vm.current_exception
  let saved_repl_exception = vm.repl_exception
  let saved_repl_active = vm.repl_active
  let saved_repl_on_error = vm.repl_on_error
  let saved_exception_handlers = vm.exception_handlers

  vm.repl_active = true
  vm.repl_on_error = false
  vm.repl_ran = true
  vm.repl_resume_value = NIL
  vm.exception_handlers = @[]
  vm.repl_exception = exception_value
  vm.current_exception = NIL

  var thrown_exception = NIL
  var repl_value = NIL
  try:
    repl_value = run_repl_session(vm, scope_tracker, scope, ns, "<repl>", "gene> ", true,
                                  nil, nil, 0, true, true)
  except CatchableError:
    if vm.current_exception != NIL:
      thrown_exception = vm.current_exception
      vm.repl_skip_on_throw = true
  if thrown_exception == NIL:
    vm.repl_resume_value = repl_value

  vm.exception_handlers = saved_exception_handlers
  vm.current_exception = saved_exception
  vm.repl_exception = saved_repl_exception
  vm.repl_active = saved_repl_active
  vm.repl_on_error = saved_repl_on_error
  vm.frame = saved_frame
  vm.cu = saved_cu
  vm.pc = saved_pc
  scope.free()

  return thrown_exception

repl_on_throw_callback = run_repl_on_throw
