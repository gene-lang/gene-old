import std/strutils

import ./gene/types
import ./gene/vm
import ./gene/vm/thread
import ./gene/parser
import ./gene/compiler

var g_eval_output = ""
var g_eval_result = ""

proc append_printed(args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool, newline: bool) =
  var buffer = ""
  let positional = get_positional_count(arg_count, has_keyword_args)
  for i in 0..<positional:
    let value = get_positional_arg(args, i, has_keyword_args)
    buffer.add(value.str_no_quotes())
    if i < positional - 1:
      buffer.add(" ")
  g_eval_output.add(buffer)
  if newline:
    g_eval_output.add("\n")

proc wasm_print(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  {.cast(gcsafe).}:
    append_printed(args, arg_count, has_keyword_args, false)
  NIL

proc wasm_println(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  {.cast(gcsafe).}:
    append_printed(args, arg_count, has_keyword_args, true)
  NIL

proc install_wasm_print_capture() =
  let print_value = wasm_print.to_value()
  let println_value = wasm_println.to_value()

  if App.app.global_ns.kind == VkNamespace:
    App.app.global_ns.ref.ns["print".to_key()] = print_value
    App.app.global_ns.ref.ns["println".to_key()] = println_value

  if App.app.gene_ns.kind == VkNamespace:
    App.app.gene_ns.ref.ns["print".to_key()] = print_value
    App.app.gene_ns.ref.ns["println".to_key()] = println_value

proc append_eval_result(result: Value) =
  if result == NIL or result == VOID:
    return
  if g_eval_output.len > 0 and not g_eval_output.endsWith("\n"):
    g_eval_output.add("\n")
  g_eval_output.add(result.str_no_quotes())

proc eval_gene_source(source: string): string =
  g_eval_output = ""

  try:
    # Fresh runtime per call keeps evaluation deterministic for host embedding.
    init_thread_pool()
    init_app_and_vm()
    set_vm_exec_callable_hook(exec_callable)
    set_vm_poll_event_loop_hook(poll_event_loop)
    init_stdlib()
    install_wasm_print_capture()

    let nodes = read_all(source)
    if nodes.len == 0:
      return ""

    let input =
      if nodes.len == 1:
        nodes[0]
      else:
        new_stream_value(nodes)

    let compiled = compile_init(input)

    let ns = new_namespace(App.app.global_ns.ref.ns, "<wasm>")
    ns["gene".to_key()] = App.app.gene_ns
    ns["genex".to_key()] = App.app.genex_ns

    VM.frame = new_frame(ns)
    let args_gene = new_gene(NIL)
    args_gene.children.add(ns.to_value())
    VM.frame.args = args_gene.to_gene_value()
    VM.cu = compiled
    VM.pc = 0

    let result = VM.exec()
    append_eval_result(result)
    g_eval_output
  except CatchableError as ex:
    if g_eval_output.len > 0 and not g_eval_output.endsWith("\n"):
      g_eval_output.add("\n")
    g_eval_output & "error: " & ex.msg
  except Defect as ex:
    if g_eval_output.len > 0 and not g_eval_output.endsWith("\n"):
      g_eval_output.add("\n")
    g_eval_output & "error: " & ex.msg

proc gene_eval*(code: cstring): cstring {.cdecl, exportc.} =
  let source = if code == nil: "" else: $code
  g_eval_result = eval_gene_source(source)
  g_eval_result.cstring

when defined(gene_wasm):
  import std/times

  var g_host_rand_state = 0x9E3779B97F4A7C15'u64

  proc host_rand_next(): int64 =
    g_host_rand_state = g_host_rand_state xor (g_host_rand_state shl 13)
    g_host_rand_state = g_host_rand_state xor (g_host_rand_state shr 7)
    g_host_rand_state = g_host_rand_state xor (g_host_rand_state shl 17)
    cast[int64](g_host_rand_state and 0x7FFF_FFFF'u64)

  proc gene_host_now*(): int64 {.cdecl, exportc.} =
    epochTime().int64

  proc gene_host_rand*(): int64 {.cdecl, exportc.} =
    host_rand_next()

  proc gene_host_file_exists*(path: cstring): cint {.cdecl, exportc.} =
    discard path
    0

  proc gene_host_read_file*(path: cstring; out_buf: ptr cstring; out_len: ptr cint): cint {.cdecl, exportc.} =
    discard path
    if out_buf != nil:
      out_buf[] = nil
    if out_len != nil:
      out_len[] = 0
    1

  proc gene_host_write_file*(path: cstring; data: cstring; len: cint): cint {.cdecl, exportc.} =
    discard path
    discard data
    discard len
    1

  proc gene_host_free*(p: pointer) {.cdecl, exportc.} =
    discard p
