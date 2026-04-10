# Gene Unit Test Framework
# Native extension for genex/test namespace
#
# Provides: TestFailure, fail, check, test!, suite! (with ^^skip support)
#
# Design:
# - Native helpers: check, fail
# - Native macros: test!, suite! (receive unevaluated body, evaluate in caller context)

{.push warning[ResultShadowed]: off.}
import ../gene/vm/extension_abi

# For static linking, don't include boilerplate to avoid duplicate set_globals
when defined(noExtensions):
  include ../gene/extension/boilerplate
else:
  # Statically linked - just import types directly
  import ../gene/types
  import ../gene/compiler
  import ../gene/vm

import tables

# Global TestFailure class reference (thread-local for safety)
var test_failure_class_global {.threadvar.}: Class

# Test counters for summary reporting
var test_pass_count {.threadvar.}: int
var test_fail_count {.threadvar.}: int
var test_skip_count {.threadvar.}: int

# Current suite depth for indentation
var suite_depth {.threadvar.}: int

proc get_indent(): string =
  result = ""
  for i in 0..<suite_depth:
    result.add("  ")

# Helper to resolve a symbol in caller's context
proc resolve_symbol_in_caller(caller_frame: Frame, name: string): Value =
  let key = name.to_key()

  # First check if it's a local variable in the caller's scope
  if caller_frame.scope != nil and caller_frame.scope.tracker != nil:
    let found = caller_frame.scope.tracker.locate(key)
    if found.local_index >= 0:
      # Variable found in scope
      var scope = caller_frame.scope
      var parent_index = found.parent_index
      while parent_index > 0:
        parent_index.dec()
        scope = scope.parent
      if found.local_index < scope.members.len:
        return scope.members[found.local_index]

  # Not a local variable, look in namespaces
  var r = caller_frame.ns[key]
  if r == NIL:
    {.cast(gcsafe).}:
      r = App.app.global_ns.ref.ns[key]
      if r == NIL:
        r = App.app.gene_ns.ref.ns[key]

  return r

# Forward declaration
proc eval_in_caller_context(vm: ptr VirtualMachine, expr: Value, caller_frame: Frame): Value

# Helper to call a callable (function, native fn, etc.) with evaluated args
proc call_in_caller_context(vm: ptr VirtualMachine, callable: Value, args: seq[Value], caller_frame: Frame): Value =
  case callable.kind:
  of VkNativeFn:
    # Call native function directly
    var args_arr = newSeq[Value](args.len)
    for i, arg in args:
      args_arr[i] = arg
    return call_native_fn(callable.ref.native_fn, vm, args_arr)

  of VkFunction:
    # Use VM's exec_function
    return vm.exec_function(callable, args)

  of VkNativeMacro:
    # Native macros receive unevaluated args - but we've already evaluated them
    # This is a limitation - native macros inside test! body won't work correctly
    {.cast(gcsafe).}:
      raise new_exception(type_defs.Exception, "Nested native macros not supported in test body")

  else:
    {.cast(gcsafe).}:
      raise new_exception(type_defs.Exception, "Cannot call value of type: " & $callable.kind)

# Helper to evaluate an expression in caller's context
proc eval_in_caller_context(vm: ptr VirtualMachine, expr: Value, caller_frame: Frame): Value =
  # Handle simple values directly
  case expr.kind:
  of VkString, VkInt, VkFloat, VkBool, VkNil:
    return expr

  of VkSymbol:
    # Direct symbol evaluation in caller's context (like IkCallerEval)
    let r = resolve_symbol_in_caller(caller_frame, expr.str)
    if r == NIL:
      {.cast(gcsafe).}:
        raise new_exception(type_defs.Exception, "Unknown symbol in caller context: " & expr.str)
    return r

  of VkQuote:
    # Evaluate the quoted expression
    return eval_in_caller_context(vm, expr.ref.quote, caller_frame)

  of VkGene:
    # For gene expressions, just compile and execute in caller's context
    # The compiler will handle operators, complex symbols, etc. correctly
    {.cast(gcsafe).}:
      let compiled = compile_init(expr)

      let saved_frame = vm.frame
      let saved_cu = vm.cu
      let saved_pc = vm.pc

      let eval_frame = new_frame()
      eval_frame.caller_frame = vm.frame
      vm.frame.ref_count.inc()
      eval_frame.ns = caller_frame.ns
      eval_frame.scope = caller_frame.scope
      if caller_frame.scope != nil:
        caller_frame.scope.ref_count.inc()
      eval_frame.from_exec_function = true

      vm.frame = eval_frame
      vm.cu = compiled
      vm.pc = 0
      result = vm.exec()

      vm.frame = saved_frame
      vm.cu = saved_cu
      vm.pc = saved_pc
      return result

  else:
    # For other types, compile and execute directly
    {.cast(gcsafe).}:
      let compiled = compile_init(expr)

      let saved_frame = vm.frame
      let saved_cu = vm.cu
      let saved_pc = vm.pc

      let eval_frame = new_frame()
      eval_frame.caller_frame = vm.frame
      vm.frame.ref_count.inc()
      eval_frame.ns = caller_frame.ns
      eval_frame.scope = caller_frame.scope
      if caller_frame.scope != nil:
        caller_frame.scope.ref_count.inc()
      eval_frame.from_exec_function = true

      vm.frame = eval_frame
      vm.cu = compiled
      vm.pc = 0
      result = vm.exec()

      vm.frame = saved_frame
      vm.cu = saved_cu
      vm.pc = saved_pc

# fail(message?) - Throws TestFailure with optional message
proc vm_fail(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let message = if get_positional_count(arg_count, has_keyword_args) > 0:
    let msg_arg = get_positional_arg(args, 0, has_keyword_args)
    if msg_arg.kind == VkString:
      msg_arg.str
    else:
      "Test failed."
  else:
    "Test failed."

  # Throw using the exception system
  {.cast(gcsafe).}:
    raise new_exception(type_defs.Exception, message)

# check(result, message?) - Fails if result is falsy
proc vm_check(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  let positional = get_positional_count(arg_count, has_keyword_args)
  if positional < 1:
    raise new_exception(type_defs.Exception, "check requires an expression result")

  let expr_result = get_positional_arg(args, 0, has_keyword_args)

  # Check if the result is truthy
  var is_truthy = true
  case expr_result.kind
  of VkNil:
    is_truthy = false
  of VkBool:
    is_truthy = expr_result == TRUE
  else:
    is_truthy = true

  if not is_truthy:
    let message = if positional > 1:
      let msg_arg = get_positional_arg(args, 1, has_keyword_args)
      if msg_arg.kind == VkString:
        msg_arg.str
      else:
        "Check failed."
    else:
      "Check failed."

    # Throw exception
    {.cast(gcsafe).}:
      raise new_exception(type_defs.Exception, message)

  return TRUE

# test! native macro - (test! ^^skip "name" body) or (test! "name" body)
proc vm_test_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    # Parse arguments from gene_value:
    # - props may contain "skip" flag (from ^^skip)
    # - children[0] = name (needs evaluation in caller context)
    # - children[1] = body (needs evaluation in caller context, with try/catch)

    let gene_args = gene_value.gene

    if gene_args.children.len < 2:
      raise new_exception(type_defs.Exception, "test! requires a name and body")

    # Check for ^^skip flag
    let skip_key = "skip".to_key()
    let skip = gene_args.props.hasKey(skip_key) and gene_args.props[skip_key] == TRUE

    # Evaluate the name in caller's context
    let name_value = eval_in_caller_context(vm, gene_args.children[0], caller_frame)
    let name = if name_value.kind == VkString:
      name_value.str
    else:
      $name_value

    let indent = get_indent()

    if skip:
      echo indent & "TEST: " & name & " ... SKIP"
      test_skip_count.inc()
      return NIL

    # Execute body with try/catch
    try:
      discard eval_in_caller_context(vm, gene_args.children[1], caller_frame)
      echo indent & "TEST: " & name & " ... PASS"
      test_pass_count.inc()
    except CatchableError as e:
      echo indent & "TEST: " & name & " ... FAIL"
      echo indent & "  " & e.msg
      test_fail_count.inc()

    return NIL

# suite! native macro - (suite! ^^skip "name" body...) or (suite! "name" body...)
proc vm_suite_macro(vm: ptr VirtualMachine, gene_value: Value, caller_frame: Frame): Value {.gcsafe.} =
  {.cast(gcsafe).}:
    # Parse arguments from gene_value:
    # - props may contain "skip" flag (from ^^skip)
    # - children[0] = name (needs evaluation in caller context)
    # - children[1..] = body expressions (evaluated in caller context)

    let gene_args = gene_value.gene

    if gene_args.children.len < 1:
      raise new_exception(type_defs.Exception, "suite! requires a name")

    # Check for ^^skip flag
    let skip_key = "skip".to_key()
    let skip = gene_args.props.hasKey(skip_key) and gene_args.props[skip_key] == TRUE

    # Evaluate the name in caller's context
    let name_value = eval_in_caller_context(vm, gene_args.children[0], caller_frame)
    let name = if name_value.kind == VkString:
      name_value.str
    else:
      $name_value

    let indent = get_indent()

    if skip:
      echo indent & "SUITE: " & name & " ... SKIP"
      return NIL

    # Start suite
    echo indent & "SUITE: " & name
    suite_depth.inc()

    # Execute body expressions
    for i in 1..<gene_args.children.len:
      discard eval_in_caller_context(vm, gene_args.children[i], caller_frame)

    # End suite
    suite_depth = max(0, suite_depth - 1)

    return NIL

# Helper to register a native function in a namespace
proc register_native_fn(ns: Namespace, name: string, fn: NativeFn) =
  let fn_ref = new_ref(VkNativeFn)
  fn_ref.native_fn = fn
  ns[name.to_key()] = fn_ref.to_ref_value()

# Helper to register a native macro in a namespace
proc register_native_macro(ns: Namespace, name: string, fn: NativeMacroFn) =
  let fn_ref = new_ref(VkNativeMacro)
  fn_ref.native_macro = fn
  ns[name.to_key()] = fn_ref.to_ref_value()

# Initialize test classes and functions
proc init_test_module*() =
  # Initialize counters
  test_pass_count = 0
  test_fail_count = 0
  test_skip_count = 0
  suite_depth = 0

  VmCreatedCallbacks.add proc() =
    # Ensure App is initialized
    if App == NIL or App.kind != VkApplication:
      return

    # Create TestFailure class extending Exception
    {.cast(gcsafe).}:
      let exception_class = if App.app.exception_class.kind == VkClass:
        App.app.exception_class.ref.class
      else:
        nil

      test_failure_class_global = new_class("TestFailure", exception_class)

    # Store class as value
    let test_failure_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      test_failure_class_ref.class = test_failure_class_global

    if App.app.genex_ns.kind == VkNamespace:
      # Create a test namespace under genex
      let test_ns = new_ref(VkNamespace)
      test_ns.ns = new_namespace("test")

      # Add TestFailure class
      test_ns.ns["TestFailure".to_key()] = test_failure_class_ref.to_ref_value()

      # Add native helper functions
      register_native_fn(test_ns.ns, "fail", vm_fail)
      register_native_fn(test_ns.ns, "check", vm_check)

      # Register native macros for test! and suite!
      register_native_macro(test_ns.ns, "test!", vm_test_macro)
      register_native_macro(test_ns.ns, "suite!", vm_suite_macro)

      # Attach to genex namespace
      App.app.genex_ns.ref.ns["test".to_key()] = test_ns.to_ref_value()

# Call init function
init_test_module()

proc init*(vm: ptr VirtualMachine): Namespace {.gcsafe.} =
  discard vm
  if App == NIL or App.kind != VkApplication:
    return nil
  if App.app.genex_ns.kind != VkNamespace:
    return nil
  let test_val = App.app.genex_ns.ref.ns.members.getOrDefault("test".to_key(), NIL)
  if test_val.kind == VkNamespace:
    return test_val.ref.ns
  return nil

proc gene_init*(host: ptr GeneHostAbi): int32 {.cdecl, exportc, dynlib.} =
  if host == nil:
    return int32(GeneExtErr)
  if host.abi_version != GENE_EXT_ABI_VERSION:
    return int32(GeneExtAbiMismatch)
  let vm = apply_extension_host_context(host)
  run_extension_vm_created_callbacks()
  let ns = init(vm)
  if host.result_namespace != nil:
    host.result_namespace[] = ns
  if ns == nil:
    return int32(GeneExtErr)
  int32(GeneExtOk)

{.pop.}
