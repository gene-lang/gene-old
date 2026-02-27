## Async compilation: compile_async, compile_await, compile_spawn, compile_yield.
## Included from compiler.nim — shares its scope (emit, compile, etc.).

proc compile_async(self: Compiler, gene: ptr Gene) =
  # (async expr)
  if gene.children.len != 1:
    not_allowed("async expects exactly 1 argument")

  # We need to wrap the expression evaluation in exception handling
  # Generate: try expr catch e -> future.fail(e)

  # Push a marker for the async block
  self.emit(Instruction(kind: IkAsyncStart))

  # Compile the expression
  self.compile(gene.children[0])

  # End async block - this will handle exceptions and wrap in future
  self.emit(Instruction(kind: IkAsyncEnd))

proc compile_await(self: Compiler, gene: ptr Gene) =
  # (await future) or (await future1 future2 ...)
  if gene.children.len == 0:
    not_allowed("await expects at least 1 argument")

  let timeout_key = "timeout".to_key()
  var timeout_arg = NIL
  var has_timeout = false
  if gene.props.has_key(timeout_key):
    timeout_arg = gene.props[timeout_key]
    if timeout_arg.kind notin {VkInt, VkFloat}:
      not_allowed("await ^timeout must be int milliseconds or float seconds")
    has_timeout = true

  if gene.children.len == 1:
    # Single future
    self.compile(gene.children[0])
    self.emit(Instruction(kind: IkAwait, arg0: timeout_arg, arg1: if has_timeout: 1 else: 0))
  else:
    # Multiple futures - await each and collect results
    self.emit(Instruction(kind: IkArrayStart))
    for child in gene.children:
      self.compile(child)
      self.emit(Instruction(kind: IkAwait, arg0: timeout_arg, arg1: if has_timeout: 1 else: 0))
      # Awaited value is on stack, will be collected by IkArrayEnd
    self.emit(Instruction(kind: IkArrayEnd))

proc compile_spawn(self: Compiler, gene: ptr Gene) =
  # (spawn expr) - spawn thread to execute expression
  # (spawn ^return true expr) or (spawn ^^return expr) - spawn and return future
  if gene.children.len == 0:
    not_allowed("spawn expects at least 1 argument")

  var return_value = false
  # Use ^return / ^^return on props
  let return_key = "return".to_key()
  if gene.props.has_key(return_key):
    let v = gene.props[return_key]
    # Treat presence with NIL/placeholder as true, otherwise use bool value
    return_value = (v == NIL or v == PLACEHOLDER) or v.to_bool()

  # Preserve full spawn body. A single form is passed directly; multiple
  # forms are wrapped as a stream so the worker executes them sequentially.
  let expr = if gene.children.len == 1:
    gene.children[0]
  else:
    new_stream_value(gene.children)

  # Pass the Gene AST as-is to the thread (it will compile locally)
  # This avoids sharing CompilationUnit refs across threads
  self.emit(Instruction(kind: IkPushValue, arg0: cast[Value](expr)))

  # Push return_value flag
  self.emit(Instruction(kind: IkPushValue, arg0: if return_value: TRUE else: FALSE))

  # Emit spawn instruction
  self.emit(Instruction(kind: IkSpawnThread))

proc compile_yield(self: Compiler, gene: ptr Gene) =
  # (yield value) - suspend generator and return value
  if gene.children.len == 0:
    # Yield without argument yields nil
    self.emit(Instruction(kind: IkPushNil))
  elif gene.children.len == 1:
    # Yield single value
    self.compile(gene.children[0])
  else:
    not_allowed("yield expects 0 or 1 argument")

  self.emit(Instruction(kind: IkYield))
