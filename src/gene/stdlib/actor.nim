import ../types
import ../vm/actor

proc init_actor_namespace*() =
  if App == NIL or App.kind != VkApplication or App.app.gene_ns.kind != VkNamespace:
    return

  let actor_ns = new_namespace("actor")
  actor_ns["enable".to_key()] = NativeFn(actor_enable_native).to_value()
  actor_ns["spawn".to_key()] = NativeFn(actor_spawn_native).to_value()

  App.app.gene_ns.ref.ns["actor".to_key()] = actor_ns.to_value()
