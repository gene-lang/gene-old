## Module helpers: ensure_namespace_path, namespace_from_value,
## run_module_init, maybe_run_module_init.
## Included from vm.nim — shares its scope.

proc ensure_namespace_path(root: Namespace, parts: seq[string], uptoExclusive: int): Namespace =
  ## Ensure that the namespace path exists (creating as needed) and return the target namespace.
  if root.is_nil:
    not_allowed("Cannot define class without an active namespace")
  var current = root
  for i in 0..<uptoExclusive:
    let key = parts[i].to_key()
    var value = if current.members.hasKey(key): current.members[key] else: NIL
    if value == NIL or value.kind != VkNamespace:
      let new_ns = new_namespace(current, parts[i])
      value = new_ns.to_value()
      current.members[key] = value
    current = value.ref.ns
  result = current

proc namespace_from_value(container: Value): Namespace =
  case container.kind
  of VkNamespace:
    result = container.ref.ns
  of VkClass:
    result = container.ref.class.ns
  else:
    not_allowed("Class container must be a namespace or class, got " & $container.kind)


proc run_module_init*(self: ptr VirtualMachine, module_ns: Namespace): tuple[ran: bool, value: Value] =
  if module_ns == nil:
    return (false, NIL)
  let ran_key = "__init_ran__".to_key()
  if module_ns.members.getOrDefault(ran_key, FALSE) == TRUE:
    return (false, NIL)
  let init_key = "__init__".to_key()
  if not module_ns.members.hasKey(init_key):
    return (false, NIL)
  let init_val = module_ns.members[init_key]
  if init_val == NIL:
    return (false, NIL)
  module_ns.members[ran_key] = TRUE

  let saved_frame = self.frame
  var frame_changed = false
  if saved_frame == nil or saved_frame.ns != module_ns:
    self.frame = new_frame(module_ns)
    frame_changed = true

  var result: Value = NIL
  let module_scope =
    if saved_frame != nil and saved_frame.ns == module_ns: saved_frame.scope else: nil

  if init_val.kind == VkFunction and module_scope != nil:
    let f = init_val.ref.fn
    if f.body_compiled == nil:
      f.compile()

    # Save current VM state
    let saved_cu = self.cu
    let saved_pc = self.pc
    let saved_frame2 = self.frame

    # Reuse module scope for init so module vars live at module scope
    module_scope.ref_count.inc()

    let args = @[module_ns.to_value()]
    if not f.matcher.is_empty():
      if args.len == 0:
        process_args_zero(f.matcher, module_scope)
      elif args.len == 1:
        process_args_one(f.matcher, args[0], module_scope)
      else:
        process_args_direct(f.matcher, cast[ptr UncheckedArray[Value]](args[0].addr), args.len, false, module_scope)

    let new_frame = new_frame()
    new_frame.kind = FkFunction
    new_frame.target = init_val
    new_frame.scope = module_scope
    new_frame.ns = f.ns
    if saved_frame2 != nil:
      saved_frame2.ref_count.inc()
    new_frame.caller_frame = saved_frame2
    new_frame.caller_address = Address(cu: saved_cu, pc: saved_pc)
    new_frame.from_exec_function = true

    let args_gene = new_gene_value()
    args_gene.gene.children.add(args[0])
    new_frame.args = args_gene

    self.frame = new_frame
    self.cu = f.body_compiled
    self.pc = 0
    result = self.exec_continue()
  else:
    result = self.exec_callable(init_val, @[module_ns.to_value()])
  if frame_changed:
    self.frame = saved_frame
  return (true, result)

proc maybe_run_module_init*(self: ptr VirtualMachine): tuple[ran: bool, value: Value] =
  if self.frame == nil or self.frame.ns == nil:
    return (false, NIL)
  let ns = self.frame.ns
  let main_key = "__is_main__".to_key()
  if ns.members.getOrDefault(main_key, FALSE) != TRUE:
    return (false, NIL)
  let init_result = self.run_module_init(ns)
  if init_result.ran:
    self.drain_pending_futures()
  return init_result
