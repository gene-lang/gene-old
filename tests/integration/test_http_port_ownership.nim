import unittest, tables, times, os

import gene/types except Exception
import gene/vm
import gene/vm/actor
import gene/vm/extension
import gene/vm/extension_abi
import gene/vm/thread

from ../../src/genex/http import gene_init, reset_http_concurrent_state_for_test,
  configure_http_handler_for_test, ensure_http_request_ports_for_test,
  dispatch_http_concurrent_request_for_test

proc build_host(): GeneHostAbi =
  GeneHostAbi(
    abi_version: GENE_EXT_ABI_VERSION,
    user_data: cast[pointer](VM),
    app_value: App,
    symbols_data: nil,
    log_message_fn: nil,
    register_scheduler_callback_fn: nil,
    register_port_fn: host_register_port_bridge,
    call_port_fn: host_call_port_bridge,
    result_namespace: nil
  )

proc await_vm_future(future_value: Value, timeout_ms = 2_000): Value =
  let deadline = epochTime() + (timeout_ms.float / 1000.0)
  let future = future_value.ref.future
  while future.state == FsPending and epochTime() < deadline:
    VM.event_loop_counter = 100
    poll_event_loop(VM)
    sleep(10)

  check future.state != FsPending
  check future.state == FsSuccess
  future.value

proc http_test_handler(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value {.gcsafe.} =
  discard vm
  discard arg_count
  let request = get_positional_arg(args, 0, has_keyword_args)
  let path = instance_props(request).getOrDefault("path".to_key(), NIL)
  let body =
    if path.kind == VkString:
      "handled:" & path.str
    else:
      "handled"
  new_map_value({
    "status".to_key(): 200.to_value(),
    "body".to_key(): body.to_value(),
    "headers".to_key(): new_map_value()
  }.toTable())

suite "HTTP actor-backed port ownership":
  test "concurrent HTTP ownership materializes actor-backed port handles":
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()
    init_actor_runtime()
    clear_registered_extension_ports_for_test()
    reset_http_concurrent_state_for_test()

    var host = build_host()
    check gene_init(addr host) == int32(GeneExtOk)

    actor_enable_for_test(2)
    let pool = ensure_http_request_ports_for_test(2)
    check pool.kind == VkArray
    check array_data(pool).len == 2
    check array_data(pool)[0].kind == VkActor
    check array_data(pool)[1].kind == VkActor

  test "concurrent HTTP dispatch resolves through actor reply futures":
    init_thread_pool()
    init_app_and_vm()
    init_stdlib()
    init_actor_runtime()
    clear_registered_extension_ports_for_test()
    reset_http_concurrent_state_for_test()

    var host = build_host()
    check gene_init(addr host) == int32(GeneExtOk)

    actor_enable_for_test(2)
    configure_http_handler_for_test(VM, NativeFn(http_test_handler).to_value())
    discard ensure_http_request_ports_for_test(2)

    let request_literal = new_map_value({
      "method".to_key(): "GET".to_value(),
      "path".to_key(): "/port".to_value(),
      "url".to_key(): "http://localhost/port".to_value(),
      "body".to_key(): NIL,
      "params".to_key(): new_map_value(),
      "headers".to_key(): new_map_value(),
      "body_params".to_key(): new_map_value()
    }.toTable())

    let future = dispatch_http_concurrent_request_for_test(VM, request_literal)
    check future.kind == VkFuture
    check future.ref.future.nim_future != nil

    let response = await_vm_future(future)
    check response.kind == VkMap
    check map_data(response)["status".to_key()].to_int == 200
    check map_data(response)["body".to_key()].str == "handled:/port"
