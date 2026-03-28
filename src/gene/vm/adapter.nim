## Interface and Adapter VM operations
##
## This module handles the runtime execution of interface definitions,
## implementations, and adapter creation/access.

import tables
import ../types

proc exec_interface(vm: ptr VirtualMachine, name: Value) =
  ## Execute IkInterface instruction - create an interface
  let interface_name = name.str
  let gene_interface = new_interface(interface_name, vm.cu.module_path)
  
  # Create the interface value
  let r = new_ref(VkInterface)
  r.gene_interface = gene_interface
  let v = r.to_ref_value()
  
  # Store in current namespace
  vm.frame.ns[interface_name.to_key()] = v
  vm.frame.push(v)

proc exec_interface_method(vm: ptr VirtualMachine, name: Value) =
  let interface_val = vm.frame.current()
  if interface_val.kind != VkInterface:
    raise new_exception(types.Exception, "interface method definition requires an interface context")
  interface_val.ref.gene_interface.add_method(name.str)

proc exec_interface_prop(vm: ptr VirtualMachine, name: Value, readonly: bool) =
  let interface_val = vm.frame.current()
  if interface_val.kind != VkInterface:
    raise new_exception(types.Exception, "interface prop definition requires an interface context")
  interface_val.ref.gene_interface.add_prop(name.str, readonly = readonly)

proc exec_implement(vm: ptr VirtualMachine, interface_name: Value, is_external: bool, has_body: bool) =
  ## Execute IkImplement instruction - register an implementation
  ## 
  ## For inline: class is passed as first argument in frame.args
  ## For external: target class is on the stack
  
  var target_class: Class
  
  if is_external:
    let target_class_val = vm.frame.pop()
    if target_class_val.kind == VkClass:
      target_class = target_class_val.ref.class
    else:
      raise new_exception(types.Exception, "implement requires a class, got " & $target_class_val.kind)
  else:
    # Inline implementation - get class from frame args (same as method definitions)
    if vm.frame.args.kind == VkGene and vm.frame.args.gene.children.len > 0:
      let class_value = vm.frame.args.gene.children[0]
      if class_value.kind == VkClass:
        target_class = class_value.ref.class
      else:
        raise new_exception(types.Exception, "inline implement can only be used inside a class")
    else:
      raise new_exception(types.Exception, "inline implement can only be used inside a class")
  
  # Look up the interface
  let interface_key = interface_name.str.to_key()
  var interface_val = vm.frame.ns.members.get_or_default(interface_key, NIL)
  if interface_val.is_nil or interface_val.kind != VkInterface:
    # Try parent namespaces
    var ns = vm.frame.ns.parent
    while not ns.is_nil:
      interface_val = ns.members.get_or_default(interface_key, NIL)
      if not interface_val.is_nil and interface_val.kind == VkInterface:
        break
      ns = ns.parent
  
  if interface_val.is_nil or interface_val.kind != VkInterface:
    raise new_exception(types.Exception, "Interface not found: " & interface_name.str)
  
  let gene_interface = interface_val.ref.gene_interface
  
  # Create implementation and register on the class
  let impl = new_implementation(gene_interface, target_class, ItkClass, is_inline = not is_external)
  target_class.register_implementation(gene_interface, impl)

  if has_body:
    if is_external:
      let context = new_gene_value()
      let class_ref = new_ref(VkClass)
      class_ref.class = target_class
      context.gene.children.add(class_ref.to_ref_value())
      context.gene.children.add(interface_val)
      vm.frame.push(context)
    else:
      let class_ref = new_ref(VkClass)
      class_ref.class = target_class
      vm.frame.push(class_ref.to_ref_value())
  else:
    vm.frame.push(NIL)
  
proc exec_implement_method(vm: ptr VirtualMachine, method_name: Value) =
  let fn_value = vm.frame.pop()
  let context = vm.frame.current()

  if context.kind != VkGene or context.gene.children.len < 2:
    raise new_exception(types.Exception, "external implement method requires an implementation context")

  let class_val = context.gene.children[0]
  let interface_val = context.gene.children[1]
  if class_val.kind != VkClass or interface_val.kind != VkInterface:
    raise new_exception(types.Exception, "invalid implementation context")

  let impl = class_val.ref.class.find_implementation(interface_val.ref.gene_interface)
  if impl.is_nil:
    raise new_exception(types.Exception, "implementation not found for external method: " & method_name.str)

  if not interface_val.ref.gene_interface.has_method(method_name.str.to_key()):
    raise new_exception(types.Exception,
      "Method " & method_name.str & " is not declared on interface " & interface_val.ref.gene_interface.name)
  impl.map_method_computed(method_name.str, fn_value)

proc exec_adapter(vm: ptr VirtualMachine) =
  ## Execute IkAdapter instruction - create an adapter wrapper
  ## Stack: [interface, inner_value]
  
  let inner = vm.frame.pop()
  let interface_val = vm.frame.pop()
  
  if interface_val.kind != VkInterface:
    raise new_exception(types.Exception, "adapter requires an interface, got " & $interface_val.kind)
  
  let gene_interface = interface_val.ref.gene_interface

  # Look up implementation on the value's class
  let inner_class = inner.get_class()
  let impl = if inner_class != nil: inner_class.find_implementation(gene_interface) else: nil

  if impl.is_nil:
    raise new_exception(types.Exception,
      "No implementation found for interface " & gene_interface.name &
      " on type " & (if inner_class != nil: inner_class.name else: $inner.kind))

  # Inline implementation — return the value directly, no wrapper
  if impl.is_inline:
    vm.frame.push(inner)
    return
  
  # Create adapter
  let adapter = new_adapter(gene_interface, inner, impl)
  
  # Create adapter value
  let r = new_ref(VkAdapter)
  r.adapter = adapter
  vm.frame.push(r.to_ref_value())

proc adapter_get_member(vm: ptr VirtualMachine, adapter: Adapter, key: Key): Value =
  ## Get a member from an adapter
  ## This handles the mapping from interface members to inner object members
  ##
  ## Special properties:
  ## - _genevalue: returns the wrapped inner value (for built-in types)
  ## - _geneinternal: returns an accessor for adapter's own supplementary data

  let gene_interface = adapter.gene_interface
  let impl = adapter.implementation

  # Special: _genevalue returns the wrapped inner value
  if key == "_genevalue".to_key():
    return adapter.inner

  # Special: _geneinternal provides access to adapter's own data
  # Returns a VkAdapterInternal that delegates member access to adapter.own_data
  if key == "_geneinternal".to_key():
    let r = new_ref(VkAdapterInternal)
    r.adapter_internal = adapter
    return r.to_ref_value()

  if adapter.own_data.has_key(key):
    return adapter.own_data[key]

  # Check if it's a property
  if gene_interface.props.has_key(key):
    let mapping = impl.prop_mappings.get_or_default(key, nil)
    if mapping.is_nil:
      # Default: direct access to inner object with same name
      if adapter.inner.kind == VkInstance and key in instance_props(adapter.inner):
        return instance_props(adapter.inner)[key]
      if adapter.inner.kind == VkMap:
        return map_data(adapter.inner).get_or_default(key, NIL)
      return NIL
    
    case mapping.kind
    of AmkRename:
      if adapter.inner.kind == VkInstance and mapping.inner_name in instance_props(adapter.inner):
        return instance_props(adapter.inner)[mapping.inner_name]
      if adapter.inner.kind == VkMap:
        return map_data(adapter.inner).get_or_default(mapping.inner_name, NIL)
      return NIL
    of AmkComputed:
      # Call the compute function with inner value as argument
      return vm.exec_callable(mapping.compute_fn, @[adapter.inner])
    of AmkHidden:
      raise new_exception(types.Exception, "Property " & $key & " is not accessible")
  
  # Check if it's a method
  if gene_interface.methods.has_key(key):
    let mapping = impl.method_mappings.get_or_default(key, nil)
    if mapping.is_nil:
      # Default: direct access to inner object's method
      if adapter.inner.kind == VkInstance:
        let inner_class = adapter.inner.instance_class
        let m = inner_class.get_method(key)
        if not m.is_nil:
          # Return a bound method
          var bm = BoundMethod(self: adapter.inner, `method`: m)
          let r = new_ref(VkBoundMethod)
          r.bound_method = bm
          return r.to_ref_value()
      raise new_exception(types.Exception, "Method " & $key & " not found on inner object")
    
    case mapping.kind
    of AmkRename:
      if adapter.inner.kind == VkInstance:
        let inner_class = adapter.inner.instance_class
        let m = inner_class.get_method(mapping.inner_name)
        if not m.is_nil:
          var bm = BoundMethod(self: adapter.inner, `method`: m)
          let r = new_ref(VkBoundMethod)
          r.bound_method = bm
          return r.to_ref_value()
      raise new_exception(types.Exception, "Method " & $mapping.inner_name & " not found on inner object")
    of AmkComputed:
      # Return the computed function directly
      return mapping.compute_fn
    of AmkHidden:
      raise new_exception(types.Exception, "Method " & $key & " is not accessible")
  
  # Not found
  return NIL

proc adapter_set_member(adapter: Adapter, key: Key, value: Value) =
  ## Set a member on an adapter
  
  let gene_interface = adapter.gene_interface
  let impl = adapter.implementation

  # Check if it's a property
  if gene_interface.props.has_key(key):
    let prop = gene_interface.props[key]
    if prop.readonly:
      raise new_exception(types.Exception, "Property " & $key & " is readonly")
    let mapping = impl.prop_mappings.get_or_default(key, nil)
    if mapping.is_nil:
      if adapter.inner.kind == VkInstance:
        instance_props(adapter.inner)[key] = value
        return
      elif adapter.inner.kind == VkMap:
        map_data(adapter.inner)[key] = value
        return
      adapter.own_data[key] = value
      return

    case mapping.kind
    of AmkRename:
      if adapter.inner.kind == VkInstance:
        instance_props(adapter.inner)[mapping.inner_name] = value
      elif adapter.inner.kind == VkMap:
        map_data(adapter.inner)[mapping.inner_name] = value
      else:
        adapter.own_data[key] = value
      return
    of AmkComputed:
      adapter.own_data[key] = value
      return
    of AmkHidden:
      raise new_exception(types.Exception, "Property " & $key & " is not accessible")

  # Store in adapter's own data
  adapter.own_data[key] = value

proc adapter_member_key(prop: Value): Key =
  case prop.kind
  of VkString, VkSymbol:
    prop.str.to_key()
  of VkInt:
    ($prop.int64).to_key()
  else:
    raise new_exception(types.Exception, "Invalid adapter property type: " & $prop.kind)

proc adapter_member_or_nil(vm: ptr VirtualMachine, adapter_val: Value, prop: Value): Value =
  let key = adapter_member_key(prop)
  adapter_get_member(vm, adapter_val.ref.adapter, key)

proc is_adapter_value*(value: Value): bool {.inline.} =
  ## Check if a value is an adapter
  value.kind == VkAdapter

proc adapter_get_inner*(value: Value): Value {.inline.} =
  ## Get the inner value from an adapter
  if value.kind == VkAdapter:
    return value.ref.adapter.inner
  return value

proc adapter_get_interface*(value: Value): GeneInterface {.inline.} =
  ## Get the interface from an adapter
  if value.kind == VkAdapter:
    return value.ref.adapter.gene_interface
  return nil

#################### Adapter Method Dispatch #######################

proc dispatch_adapter_method(vm: ptr VirtualMachine, obj: Value, method_name: string, args: seq[Value]): Value =
  ## Dispatch a method call on an adapter, resolving through the interface mapping.
  let member = adapter_get_member(vm, obj.ref.adapter, method_name.to_key())
  if member == NIL or member == VOID:
    not_allowed("Method " & method_name & " not found on Adapter")
  case member.kind
  of VkFunction:
    vm.exec_method_impl(member, obj, args, vm.frame)
  of VkBoundMethod:
    let bm = member.ref.bound_method
    if bm.`method`.callable.kind == VkFunction:
      vm.exec_method_impl(bm.`method`.callable, bm.self, args, vm.frame)
    else:
      vm.exec_callable(member, args)
  else:
    vm.exec_callable_with_self(member, obj, args)

proc dispatch_adapter_method_kw(vm: ptr VirtualMachine, obj: Value, method_name: string, args: seq[Value], kw_pairs: seq[(Key, Value)]): Value =
  ## Dispatch a keyword-args method call on an adapter.
  let member = adapter_get_member(vm, obj.ref.adapter, method_name.to_key())
  if member == NIL or member == VOID:
    not_allowed("Method " & method_name & " not found on Adapter")
  case member.kind
  of VkFunction:
    vm.exec_method_kw_impl(member, obj, args, kw_pairs, vm.frame)
  of VkBoundMethod:
    let bm = member.ref.bound_method
    if bm.`method`.callable.kind == VkFunction:
      vm.exec_method_kw_impl(bm.`method`.callable, bm.self, args, kw_pairs, vm.frame)
    else:
      if kw_pairs.len > 0:
        not_allowed("Keyword arguments are not supported for adapter bound method kind: " & $bm.`method`.callable.kind)
      vm.exec_callable(member, args)
  else:
    if kw_pairs.len > 0:
      not_allowed("Keyword arguments are not supported for adapter method kind: " & $member.kind)
    vm.exec_callable_with_self(member, obj, args)

#################### Adapter Internal Access #######################

proc adapter_internal_get_member*(adapter_internal_val: Value, key: Key): Value =
  ## Get a member from adapter's internal data via VkAdapterInternal
  if adapter_internal_val.kind != VkAdapterInternal:
    raise new_exception(types.Exception, "Expected VkAdapterInternal")
  let adapter = adapter_internal_val.ref.adapter_internal
  return adapter.own_data.get_or_default(key, NIL)

proc adapter_internal_set_member*(adapter_internal_val: Value, key: Key, value: Value) =
  ## Set a member in adapter's internal data via VkAdapterInternal
  if adapter_internal_val.kind != VkAdapterInternal:
    raise new_exception(types.Exception, "Expected VkAdapterInternal")
  let adapter = adapter_internal_val.ref.adapter_internal
  adapter.own_data[key] = value

proc adapter_internal_member_or_nil*(adapter_internal_val: Value, prop: Value): Value =
  ## Get a member from adapter internal data, returning NIL if not found
  let key = adapter_member_key(prop)
  adapter_internal_get_member(adapter_internal_val, key)

