import std/[os, strutils, tables, times, unittest]

import gene/types except Exception
import gene/vm
import gene/vm/actor
import gene/vm/extension
import gene/vm/extension_abi
import gene/vm/thread

from ../../src/genex/http import gene_init, reset_http_concurrent_state_for_test,
  configure_http_handler_for_test, ensure_http_request_ports_for_test,
  try_dispatch_http_concurrent_request_for_test, dispatch_http_concurrent_request_for_test,
  configure_http_backpressure_for_test, configure_http_request_timeout_for_test,
  http_backpressure_status_for_test, wait_http_response_future_for_test,
  try_begin_http_in_flight_for_test, finish_http_in_flight_for_test,
  HttpActorDispatchStatus, HttpFutureResponseStatus

proc build_host(): GeneHostAbi =
  GeneHostAbi(
    abi_version: GENE_EXT_ABI_VERSION,
    user_data: cast[pointer](VM),
    app_value: App,
    symbols_data: nil,
    log_message_fn: nil,
    register_scheduler_callback_fn: nil,
    register_port_fn: host_register_port_bridge,
    register_port_with_options_fn: host_register_port_with_options_bridge,
    call_port_fn: host_call_port_bridge,
    call_port_async_fn: host_call_port_async_bridge,
    actor_reply_fn: host_actor_reply_bridge,
    actor_reply_serialized_fn: host_actor_reply_serialized_bridge,
    poll_vm_fn: host_poll_vm_bridge,
    result_namespace: nil
  )

proc request_literal(path: string): Value =
  new_map_value({
    "method".to_key(): "GET".to_value(),
    "path".to_key(): path.to_value(),
    "url".to_key(): ("http://localhost" & path).to_value(),
    "body".to_key(): NIL,
    "params".to_key(): new_map_value(),
    "headers".to_key(): new_map_value(),
    "body_params".to_key(): new_map_value()
  }.toTable())

proc response_body(response: Value): string =
  if response.kind != VkMap:
    return ""
  let body = map_data(response).getOrDefault("body".to_key(), NIL)
  if body.kind == VkString: body.str else: $body

proc await_vm_future(future_value: Value, timeout_ms = 2_000): Value =
  let deadline = epochTime() + (timeout_ms.float / 1000.0)
  let future = future_value.ref.future
  while future.state == FsPending and epochTime() < deadline:
    VM.event_loop_counter = 100
    poll_event_loop(VM)
    sleep(5)

  check future.state != FsPending
  check future.state == FsSuccess
  future.value

proc readiness_handler(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                       has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  discard vm
  discard arg_count
  let request = get_positional_arg(args, 0, has_keyword_args)
  let path_value = instance_props(request).getOrDefault("path".to_key(), NIL)
  let path = if path_value.kind == VkString: path_value.str else: "/unknown"

  if path == "/slow":
    sleep(220)
  if path == "/boom":
    raise new_exception(types.Exception, "handler boom")

  new_map_value({
    "status".to_key(): 200.to_value(),
    "body".to_key(): ("ok:" & path).to_value(),
    "headers".to_key(): new_map_value()
  }.toTable())

proc init_http_actor_test(workers: int, queue_limit = 1) =
  init_thread_pool()
  init_app_and_vm()
  init_stdlib()
  init_actor_runtime()
  clear_registered_extension_ports_for_test()
  reset_http_concurrent_state_for_test()

  var host = build_host()
  check gene_init(addr host) == int32(GeneExtOk)

  actor_enable_for_test(workers)
  configure_http_handler_for_test(VM, NativeFn(readiness_handler).to_value())
  configure_http_backpressure_for_test(queue_limit, 100, 503)
  discard ensure_http_request_ports_for_test(workers)

suite "Actor-backed HTTP readiness backpressure":
  test "tiny actor queue returns overload immediately and later success still works":
    init_http_actor_test(1, 1)

    let first = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/slow"))
    check first.status == HadsAccepted
    check first.future.kind == VkFuture

    sleep(60)
    let queued = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/slow"))
    check queued.status == HadsAccepted

    let started = epochTime()
    let overloaded = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/slow"))
    let elapsed_ms = (epochTime() - started) * 1000.0

    check overloaded.status == HadsOverloaded
    check overloaded.future == NIL
    check elapsed_ms < 50.0

    check response_body(await_vm_future(first.future)) == "ok:/slow"
    check response_body(await_vm_future(queued.future)) == "ok:/slow"

    let health = dispatch_http_concurrent_request_for_test(VM, request_literal("/health"))
    check response_body(await_vm_future(health)) == "ok:/health"

  test "round-robin try dispatch keeps another worker responsive while one is busy":
    init_http_actor_test(2, 1)

    let slow = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/slow"))
    check slow.status == HadsAccepted

    let started = epochTime()
    let health = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/health"))
    let health_response = await_vm_future(health.future, 500)
    let elapsed_ms = (epochTime() - started) * 1000.0

    check health.status == HadsAccepted
    check response_body(health_response) == "ok:/health"
    check elapsed_ms < 150.0

    check response_body(await_vm_future(slow.future)) == "ok:/slow"

  test "stopped actor port maps to a safe dispatch status":
    init_http_actor_test(1, 1)

    let pool = ensure_http_request_ports_for_test(1)
    let actor = array_data(pool)[0]
    App.app.gene_ns.ref.ns["stopped_http_port".to_key()] = actor
    App.app.global_ns.ref.ns["stopped_http_port".to_key()] = actor
    discard VM.exec("(stopped_http_port .stop)", "stop_http_port.gene")

    let stopped = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/health"))

    check stopped.status == HadsStopped
    check stopped.future == NIL

  test "backpressure configuration rejects invalid queue and in-flight limits":
    init_http_actor_test(1, 1)

    expect types.Exception:
      configure_http_backpressure_for_test(0, 1, 503)
    expect types.Exception:
      configure_http_backpressure_for_test(-1, 1, 503)
    expect types.Exception:
      configure_http_backpressure_for_test(10_001, 1, 503)
    expect types.Exception:
      configure_http_backpressure_for_test(1, 0, 503)
    expect types.Exception:
      configure_http_backpressure_for_test(1, -1, 503)
    expect types.Exception:
      configure_http_backpressure_for_test(1, 10_001, 503)
    expect types.Exception:
      configure_http_backpressure_for_test(1, 1, 200)

  test "request timeout config rejects invalid values":
    init_http_actor_test(1, 1)

    configure_http_request_timeout_for_test(25)
    check http_backpressure_status_for_test().request_timeout_ms == 25

    expect types.Exception:
      configure_http_request_timeout_for_test(0)
    expect types.Exception:
      configure_http_request_timeout_for_test(-1)
    expect types.Exception:
      configure_http_request_timeout_for_test(600_001)

  test "slow actor reply times out, detaches tracking, and ignores stale completion":
    init_http_actor_test(1, 1)
    configure_http_request_timeout_for_test(30)

    let dispatch = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/slow"))
    check dispatch.status == HadsAccepted
    check dispatch.future.kind == VkFuture
    check VM.thread_futures.len == 1

    let started = epochTime()
    let timed_out = wait_http_response_future_for_test(VM, dispatch.future)
    let elapsed_ms = (epochTime() - started) * 1000.0

    check timed_out.status == HfrTimeout
    check timed_out.http_status == 504
    check timed_out.body == "Async response error: await timed out"
    check elapsed_ms < 180.0
    check dispatch.future.ref.future.state == FsFailure
    check VM.thread_futures.len == 0

    let timeout_status = http_backpressure_status_for_test()
    check timeout_status.timeout_count == 1
    check timeout_status.request_timeout_ms == 30
    check timeout_status.last_timeout_error == "GENE.ASYNC.TIMEOUT: await timed out"
    check timeout_status.last_timeout_at.len > 0

    sleep(260)
    VM.event_loop_counter = 100
    poll_event_loop(VM)
    check dispatch.future.ref.future.state == FsFailure
    check VM.thread_futures.len == 0

  test "handler failure before timeout is returned as failure response, not timeout":
    init_http_actor_test(1, 1)
    configure_http_request_timeout_for_test(500)

    let dispatch = try_dispatch_http_concurrent_request_for_test(VM, request_literal("/boom"))
    check dispatch.status == HadsAccepted

    let waited = wait_http_response_future_for_test(VM, dispatch.future)
    check waited.status == HfrSuccess
    check waited.response.kind == VkMap
    check map_data(waited.response)["status".to_key()].to_int == 500
    check "handler boom" in response_body(waited.response)
    check http_backpressure_status_for_test().timeout_count == 0

  test "configured max_in_flight rejects excess accepted requests deterministically":
    init_http_actor_test(1, 1)
    configure_http_backpressure_for_test(1, 1, 503)

    check try_begin_http_in_flight_for_test() == HadsAccepted
    check try_begin_http_in_flight_for_test() == HadsLimitExceeded

    var status = http_backpressure_status_for_test()
    check status.in_flight == 1

    finish_http_in_flight_for_test()
    check try_begin_http_in_flight_for_test() == HadsAccepted
    finish_http_in_flight_for_test()

  test "overload status and body are deterministic":
    init_http_actor_test(1, 1)

    let defaults = http_backpressure_status_for_test()
    check defaults.overload_status == 503
    check defaults.overload_body == "Service overloaded"
    check defaults.request_timeout_ms == 10_000

    configure_http_backpressure_for_test(1, 1, 429)
    configure_http_request_timeout_for_test(75)
    let configured = http_backpressure_status_for_test()
    check configured.queue_limit == 1
    check configured.max_in_flight == 1
    check configured.overload_status == 429
    check configured.overload_body == "Service overloaded"
    check configured.request_timeout_ms == 75
