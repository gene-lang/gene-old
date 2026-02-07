{.push warning[ResultShadowed]: off.}
import ../types

proc new_generator_value*(f: Function, args: seq[Value]): Value {.inline.} =
  ## Helper for constructing generator instances.
  var gen_ref = new_ref(VkGenerator)
  var gen_obj: GeneratorObj
  new(gen_obj)
  gen_obj.function = f
  gen_obj.state = GsPending
  gen_obj.frame = nil
  gen_obj.cu = nil
  gen_obj.pc = 0
  gen_obj.scope = nil
  gen_obj.stack = args
  gen_obj.done = false
  gen_obj.has_peeked = false
  gen_obj.peeked_value = NIL
  gen_ref.generator = gen_obj
  result = gen_ref.to_ref_value()

# Forward declaration
proc exec_generator*(self: ptr VirtualMachine, gen: GeneratorObj): Value {.gcsafe.}

# Initialize generator support
proc init_generator*() =
  VmCreatedCallbacks.add proc() =
    # Ensure App is initialized
    if App == NIL or App.kind != VkApplication:
      return

    let generator_class = new_class("Generator")

    # Add next method - for now just returns VOID
    proc generator_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
      # Get next value from generator
      if arg_count < 1:
        raise new_exception(types.Exception, "Generator.next requires a generator")

      let gen_arg = get_positional_arg(args, 0, has_keyword_args)
      if gen_arg.kind != VkGenerator:
        raise new_exception(types.Exception, "next can only be called on a Generator")

      # Get the generator object
      let gen = gen_arg.ref.generator

      # Check if generator is nil
      if gen == nil:
        raise new_exception(types.Exception, "Generator object is nil")

      # If we have a peeked value, return it and clear the peek
      if gen != nil and gen.has_peeked:
        gen.has_peeked = false
        let val = gen.peeked_value
        gen.peeked_value = NIL
        return val

      # Otherwise, get the next value normally
      if gen.done:
        return NOT_FOUND


      # Execute the generator until next yield
      let result = exec_generator(vm, gen)
      return result

    proc generator_has_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
      # Check if generator has a next value without consuming it
      if arg_count < 1:
        raise new_exception(types.Exception, "Generator.has_next requires a generator")

      let gen_arg = get_positional_arg(args, 0, has_keyword_args)
      if gen_arg.kind != VkGenerator:
        raise new_exception(types.Exception, "has_next can only be called on a Generator")

      # Get the generator object
      let gen = gen_arg.ref.generator

      # Check if generator is nil
      if gen == nil:
        raise new_exception(types.Exception, "Generator object is nil")

      # If we already have a peeked value, return true
      if gen.has_peeked:
        return TRUE

      # If generator is done, return false
      if gen.done:
        return FALSE

      # Otherwise, try to get the next value without consuming it
      let next_val = exec_generator(vm, gen)


      # Store the peeked value
      if next_val == NOT_FOUND:
        # Generator is exhausted, don't store NOT_FOUND as peeked
        # gen.done was already set by exec_generator
        return FALSE
      else:
        gen.has_peeked = true
        gen.peeked_value = next_val
        return TRUE

    # Add methods to generator class
    generator_class.def_native_method("next", generator_next)
    generator_class.def_native_method("has_next", generator_has_next)

    # Store in Application
    let generator_class_ref = new_ref(VkClass)
    generator_class_ref.class = generator_class
    App.app.generator_class = generator_class_ref.to_ref_value()

    # Add to gene namespace if it exists
    if App.app.gene_ns.kind == VkNamespace:
      App.app.gene_ns.ref.ns["Generator".to_key()] = App.app.generator_class

# Call init_generator to register the callback
init_generator()

# Declare exec_generator_impl which will be in vm.nim
proc exec_generator_impl*(self: ptr VirtualMachine, gen: GeneratorObj): Value {.importc, gcsafe.}

# Execute generator until it yields or completes
proc exec_generator*(self: ptr VirtualMachine, gen: GeneratorObj): Value {.gcsafe.} =
  # Use the implementation in vm.nim
  return exec_generator_impl(self, gen)

{.pop.}
