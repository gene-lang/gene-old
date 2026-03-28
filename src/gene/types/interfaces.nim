## Interface and Adapter type helpers
##
## This module provides helper functions for creating and manipulating
## interfaces and adapters in the Gene language.

import tables
import ./type_defs
import ./core

#################### Interface #######################

proc new_interface*(name: string, module_path: string = ""): GeneInterface =
  ## Create a new interface with the given name
  GeneInterface(
    name: name,
    module_path: module_path,
    methods: initTable[Key, InterfaceMethod](),
    props: initTable[Key, InterfaceProp](),
    ns: new_namespace(nil, name)
  )

proc add_method*(self: GeneInterface, name: string, callable: Value = NIL, type_id: TypeId = NO_TYPE_ID) =
  ## Add a method signature to the interface
  self.methods[name.to_key()] = InterfaceMethod(
    name: name,
    callable: callable,
    type_id: type_id
  )

proc add_prop*(self: GeneInterface, name: string, type_id: TypeId = NO_TYPE_ID, readonly: bool = false) =
  ## Add a property signature to the interface
  self.props[name.to_key()] = InterfaceProp(
    name: name,
    type_id: type_id,
    readonly: readonly
  )

proc has_method*(self: GeneInterface, name: Key): bool {.inline.} =
  self.methods.has_key(name)

proc has_prop*(self: GeneInterface, name: Key): bool {.inline.} =
  self.props.has_key(name)

proc get_method*(self: GeneInterface, name: Key): InterfaceMethod {.inline.} =
  self.methods.get_or_default(name, nil)

proc get_prop*(self: GeneInterface, name: Key): InterfaceProp {.inline.} =
  self.props.get_or_default(name, nil)

#################### Implementation #######################

proc new_implementation*(gene_interface: GeneInterface, target_class: Class = nil,
                         target_kind: ImplementationTargetKind = ItkClass,
                         is_inline: bool = false): Implementation =
  ## Create a new implementation connecting a class to an interface
  Implementation(
    gene_interface: gene_interface,
    target_class: target_class,
    target_kind: target_kind,
    is_inline: is_inline,
    method_mappings: initTable[Key, AdapterMapping](),
    prop_mappings: initTable[Key, AdapterMapping](),
    own_data: initTable[Key, Value]()
  )

proc map_method_rename*(self: Implementation, interface_method: string, inner_method: string) =
  ## Map an interface method to a method with a different name on the inner object
  self.method_mappings[interface_method.to_key()] = AdapterMapping(
    kind: AmkRename,
    inner_name: inner_method.to_key()
  )

proc map_method_computed*(self: Implementation, interface_method: string, compute_fn: Value) =
  ## Map an interface method to a computed function
  self.method_mappings[interface_method.to_key()] = AdapterMapping(
    kind: AmkComputed,
    compute_fn: compute_fn
  )

proc map_method_hidden*(self: Implementation, interface_method: string) =
  ## Hide an interface method (not implemented)
  self.method_mappings[interface_method.to_key()] = AdapterMapping(
    kind: AmkHidden
  )

proc map_prop_rename*(self: Implementation, interface_prop: string, inner_prop: string) =
  ## Map an interface property to a property with a different name on the inner object
  self.prop_mappings[interface_prop.to_key()] = AdapterMapping(
    kind: AmkRename,
    inner_name: inner_prop.to_key()
  )

proc map_prop_computed*(self: Implementation, interface_prop: string, compute_fn: Value) =
  ## Map an interface property to a computed function
  self.prop_mappings[interface_prop.to_key()] = AdapterMapping(
    kind: AmkComputed,
    compute_fn: compute_fn
  )

proc map_prop_hidden*(self: Implementation, interface_prop: string) =
  ## Hide an interface property (not implemented)
  self.prop_mappings[interface_prop.to_key()] = AdapterMapping(
    kind: AmkHidden
  )

#################### Adapter #######################

proc new_adapter*(gene_interface: GeneInterface, inner: Value, implementation: Implementation): Adapter =
  ## Create a new adapter wrapping a value
  Adapter(
    gene_interface: gene_interface,
    inner: inner,
    implementation: implementation,
    own_data: initTable[Key, Value]()
  )

proc is_adapter*(value: Value): bool {.inline.} =
  ## Check if a value is an adapter
  value.kind == VkAdapter

proc get_adapter*(value: Value): Adapter {.inline.} =
  ## Get the adapter from a value (assumes is_adapter is true)
  value.ref.adapter

proc get_inner*(self: Adapter): Value {.inline.} =
  ## Get the wrapped inner value
  self.inner

proc unwrap_adapter*(value: Value): Value =
  ## Recursively unwrap adapters to get the innermost value
  result = value
  while result.kind == VkAdapter:
    result = result.ref.adapter.inner

#################### Class Implementation Lookup #######################

proc register_implementation*(self: Class, gene_interface: GeneInterface, impl: Implementation) =
  ## Register an implementation for an interface on this class
  self.implementations[gene_interface.name.to_key()] = impl

proc find_implementation*(self: Class, gene_interface: GeneInterface): Implementation =
  ## Find an implementation for an interface on this class
  self.implementations.get_or_default(gene_interface.name.to_key(), nil)
