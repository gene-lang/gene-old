import unittest

import ../src/gene/types except Exception
import ../src/gene/types/type_defs except Exception
import ../src/gene/types/runtime_types
import ../src/gene/vm
import ./helpers

var actor_runtime_types_ready = false

proc actor_marker(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                  has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  "Actor".to_value()

proc actor_context_marker(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int,
                          has_keyword_args: bool): Value {.gcsafe, nimcall.} =
  "ActorContext".to_value()

proc install_actor_runtime_test_surface() =
  init_all()
  if actor_runtime_types_ready:
    return

  let actor_class = new_class("Actor")
  actor_class.parent = App.app.object_class.ref.class
  actor_class.def_native_method("marker", actor_marker)

  let actor_context_class = new_class("ActorContext")
  actor_context_class.parent = App.app.object_class.ref.class
  actor_context_class.def_native_method("marker", actor_context_marker)

  let actor_class_ref = new_ref(VkClass)
  actor_class_ref.class = actor_class
  App.app.actor_class = actor_class_ref.to_ref_value()
  App.app.global_ns.ns["Actor".to_key()] = App.app.actor_class

  let actor_context_class_ref = new_ref(VkClass)
  actor_context_class_ref.class = actor_context_class
  App.app.actor_context_class = actor_context_class_ref.to_ref_value()
  App.app.global_ns.ns["ActorContext".to_key()] = App.app.actor_context_class

  let actor_handle = Actor(id: 7)
  let actor_context = ActorContext(actor: actor_handle)
  App.app.global_ns.ns["actor_value".to_key()] = actor_handle.to_value()
  App.app.global_ns.ns["actor_context_value".to_key()] = actor_context.to_value()

  actor_runtime_types_ready = true

suite "Actor runtime types":
  install_actor_runtime_test_surface()

  test "actor kinds extend the runtime surface":
    check VkActor.ord > VkThreadMessage.ord
    check VkActorContext.ord == VkActor.ord + 1

  test "boxed actors expose stable runtime type names":
    let actor_value = App.app.global_ns.ns["actor_value".to_key()]
    let actor_context_value = App.app.global_ns.ns["actor_context_value".to_key()]
    let thread_value = type_defs.Thread(id: 11, secret: 29).to_value()

    check actor_value.kind == VkActor
    check actor_context_value.kind == VkActorContext
    check actor_value.ref.actor.id == 7
    check actor_context_value.ref.actor_context.actor.id == 7
    check runtime_type_name(actor_value) == "Actor"
    check runtime_type_name(actor_context_value) == "ActorContext"
    check runtime_type_name(thread_value) == "Thread"

  test "boxed actors resolve methods through actor runtime classes":
    check VM.exec("(actor_value .marker)", "actor-runtime-types") == "Actor".to_value()
    check VM.exec("(actor_context_value .marker)", "actor-runtime-types") == "ActorContext".to_value()
