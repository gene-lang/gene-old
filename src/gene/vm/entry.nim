## Top-level entry points: exec*(code: string), exec*(stream: Stream).
## Included from vm.nim — shares its scope.

proc exec*(self: ptr VirtualMachine, code: string, module_name: string): Value =
  let compiled = parse_and_compile(code, module_name, module_mode = true, run_init = false, type_check = self.type_check)

  let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
  ns["__module_name__".to_key()] = module_name.to_value()
  ns["__is_main__".to_key()] = TRUE

  # Add gene namespace to module namespace
  ns["gene".to_key()] = App.app.gene_ns
  ns["genex".to_key()] = App.app.genex_ns
  App.app.gene_ns.ref.ns["main_module".to_key()] = module_name.to_value()

  # Add eval function to the module namespace
  # Add eval function to the namespace if it exists in global_ns
  # NOTE: This line causes issues with reference access in some cases, commenting out for now
  # if App.app.global_ns.kind == VkNamespace:
  #   let global_ns = App.app.global_ns.ref.ns
  #   if global_ns.has_key("eval".to_key()):
  #     ns["eval".to_key()] = global_ns["eval".to_key()]

  # Initialize frame if it doesn't exist
  if self.frame == nil:
    self.frame = new_frame(ns)
  else:
    self.frame.update(new_frame(ns))

  # Self is now passed as argument, not stored in frame
  let args_gene = new_gene(NIL)
  args_gene.children.add(ns.to_value())
  self.frame.args = args_gene.to_gene_value()
  self.cu = compiled

  let result = self.exec()
  let init_result = self.maybe_run_module_init()
  if init_result.ran:
    return init_result.value
  return result

proc exec*(self: ptr VirtualMachine, stream: Stream, module_name: string): Value =
  ## Execute Gene code from a stream (more memory-efficient for large files)
  let compiled = parse_and_compile(stream, module_name, module_mode = true, run_init = false, type_check = self.type_check)

  let ns = new_namespace(App.app.global_ns.ref.ns, module_name)
  ns["__module_name__".to_key()] = module_name.to_value()
  ns["__is_main__".to_key()] = TRUE

  # Add gene namespace to module namespace
  ns["gene".to_key()] = App.app.gene_ns
  ns["genex".to_key()] = App.app.genex_ns
  App.app.gene_ns.ref.ns["main_module".to_key()] = module_name.to_value()

  # Initialize frame if it doesn't exist
  if self.frame == nil:
    self.frame = new_frame(ns)
  else:
    self.frame.update(new_frame(ns))

  # Self is now passed as argument, not stored in frame
  let args_gene = new_gene(NIL)
  args_gene.children.add(ns.to_value())
  self.frame.args = args_gene.to_gene_value()
  self.cu = compiled

  let result = self.exec()
  let init_result = self.maybe_run_module_init()
  if init_result.ran:
    return init_result.value
  return result
