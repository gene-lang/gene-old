import tables

import ./type_defs
import ./core

#################### Class #######################

proc new_class*(name: string, parent: Class): Class =
  result = Class(
    name: name,
    ns: new_namespace(nil, name),
    parent: parent,
    constructor: NIL,
    members: initTable[Key, Value](),
    methods: initTable[Key, Method](),
    version: 0,
    has_macro_constructor: false,  # Initialize to false, will be set during constructor compilation
  )

proc new_class*(name: string): Class =
  var parent: Class
  # if VM.object_class != nil:
  #   parent = VM.object_class.class
  new_class(name, parent)

proc get_constructor*(self: Class): Value =
  if self.constructor.is_nil:
    if not self.parent.is_nil:
      return self.parent.get_constructor()
  else:
    return self.constructor

proc has_method*(self: Class, name: Key): bool {.inline.} =
  if self.methods.has_key(name):
    return true
  elif self.parent != nil:
    return self.parent.has_method(name)

proc has_method*(self: Class, name: string): bool {.inline.} =
  self.has_method(name.to_key)

proc get_method*(self: Class, name: Key): Method {.inline.} =
  let found = self.methods.get_or_default(name, nil)
  if not found.is_nil:
    return found
  elif self.parent != nil:
    return self.parent.get_method(name)
  # else:
  #   not_allowed("No method available: " & name.to_s)

proc get_method*(self: Class, name: string): Method {.inline.} =
  self.get_method(name.to_key)

proc get_super_method*(self: Class, name: string): Method {.inline.} =
  if self.parent != nil:
    return self.parent.get_method(name)
  else:
    not_allowed("No super method available: " & name)

proc get_class*(val: Value): Class {.inline.} =
  case val.kind:
    of VkApplication:
      return App.ref.app.application_class.ref.class
    of VkPackage:
      return App.ref.app.package_class.ref.class
    of VkInstance:
      return val.instance_class
    of VkCustom:
      if val.ref.custom_class != nil:
        return val.ref.custom_class
      else:
        return App.ref.app.object_class.ref.class
    # of VkCast:
    #   return val.cast_class
    of VkClass:
      return App.ref.app.class_class.ref.class
    of VkNamespace:
      return App.ref.app.namespace_class.ref.class
    of VkInterface:
      if App.ref.app.interface_class.kind == VkClass:
        return App.ref.app.interface_class.ref.class
      else:
        return App.ref.app.object_class.ref.class
    of VkAdapter:
      if App.ref.app.adapter_class.kind == VkClass:
        return App.ref.app.adapter_class.ref.class
      else:
        return App.ref.app.object_class.ref.class
    of VkFuture:
      if App.ref.app.future_class.kind == VkClass:
        return App.ref.app.future_class.ref.class
      else:
        return nil
    of VkGenerator:
      if App.ref.app.generator_class.kind == VkClass:
        return App.ref.app.generator_class.ref.class
      else:
        return nil
    of VkAspect:
      if App.ref.app.aspect_class.kind == VkClass:
        return App.ref.app.aspect_class.ref.class
      else:
        return nil
    # of VkThread:
    #   return App.ref.app.thread_class.ref.class
    # of VkThreadMessage:
    #   return App.ref.app.thread_message_class.ref.class
    # of VkNativeFile:
    #   return App.ref.app.file_class.ref.class
    # of VkException:
    #   let ex = val.exception
    #   if ex is ref Exception:
    #     let ex = cast[ref Exception](ex)
    #     if ex.instance != nil:
    #       return ex.instance.instance_class
    #     else:
    #       return App.ref.app.exception_class.ref.class
    #   else:
    #     return App.ref.app.exception_class.ref.class
    of VkNil:
      return App.ref.app.nil_class.ref.class
    of VkBool:
      return App.ref.app.bool_class.ref.class
    of VkInt:
      return App.ref.app.int_class.ref.class
    of VkFloat:
      return App.ref.app.float_class.ref.class
    of VkChar:
      return App.ref.app.char_class.ref.class
    of VkString:
      return App.ref.app.string_class.ref.class
    of VkSymbol:
      return App.ref.app.symbol_class.ref.class
    of VkComplexSymbol:
      return App.ref.app.complex_symbol_class.ref.class
    of VkArray:
      return App.ref.app.array_class.ref.class
    of VkMap:
      return App.ref.app.map_class.ref.class
    of VkSet:
      return App.ref.app.set_class.ref.class
    of VkGene:
      return App.ref.app.gene_class.ref.class
    of VkRegex:
      return App.ref.app.regex_class.ref.class
    of VkRange:
      return App.ref.app.range_class.ref.class
    # of VkDate:
    #   return App.ref.app.date_class.ref.class
    # of VkDateTime:
    #   return App.ref.app.datetime_class.ref.class
    # of VkTime:
    #   return App.ref.app.time_class.ref.class
    of VkFunction:
      return App.ref.app.function_class.ref.class
    # of VkTimezone:
    #   return App.ref.app.timezone_class.ref.class
    # of VkAny:
    #   if val.any_class == nil:
    #     return App.ref.app.object_class.ref.class
    #   else:
    #     return val.any_class
    # of VkCustom:
    #   if val.custom_class == nil:
    #     return App.ref.app.object_class.ref.class
    #   else:
    #     return val.custom_class
    else:
      todo("get_class " & $val.kind)

proc has_object_class*(val: Value): bool {.inline.} =
  case val.kind
  of VkInstance, VkCustom:
    true
  else:
    false

proc get_object_class*(val: Value): Class {.inline.} =
  case val.kind
  of VkInstance:
    val.instance_class
  of VkCustom:
    val.ref.custom_class
  else:
    nil

proc require_object_class*(val: Value, context: string): Class {.inline.} =
  let cls = val.get_object_class()
  if cls.is_nil:
    raise new_exception(type_defs.Exception, context)
  cls

proc object_class_name*(val: Value): string {.inline.} =
  let cls = val.get_object_class()
  if cls.is_nil or cls.name.len == 0:
    return "UnknownObject"
  cls.name

proc is_a*(self: Value, class: Class): bool {.inline.} =
  var my_class = self.get_class
  while true:
    if my_class == class:
      return true
    if my_class.parent == nil:
      return false
    else:
      my_class = my_class.parent

proc def_native_method*(self: Class, name: string, f: NativeFn,
                        params: openArray[(string, Value)],
                        returns: Value = NIL) =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  var native_params: seq[(string, Value)] = @[]
  for p in params:
    native_params.add((p[0], p[1]))
  self.methods[name.to_key()] = Method(
    class: self,
    name: name,
    callable: r.to_ref_value(),
    native_signature_known: true,
    native_param_types: native_params,
    native_return_type: returns,
  )
  self.version.inc()

proc def_native_method*(self: Class, name: string, f: NativeFn) =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  var native_params: seq[(string, Value)]
  self.methods[name.to_key()] = Method(
    class: self,
    name: name,
    callable: r.to_ref_value(),
    native_signature_known: false,
    native_param_types: native_params,
    native_return_type: NIL,
  )
  self.version.inc()

proc def_member*(self: Class, name: string, value: Value) =
  self.members[name.to_key()] = value
  self.version.inc()

proc def_static_method*(self: Class, name: string, f: NativeFn) =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  self.members[name.to_key()] = r.to_ref_value()
  self.version.inc()

proc get_member*(self: Class, name: Key): Value =
  if self.members.hasKey(name):
    return self.members[name]
  if not self.parent.is_nil:
    return self.parent.get_member(name)
  return NIL

proc def_native_constructor*(self: Class, f: NativeFn) =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  self.constructor = r.to_ref_value()

proc def_native_macro_method*(self: Class, name: string, f: NativeFn) =
  let r = new_ref(VkNativeFn)
  r.native_fn = f
  self.methods[name.to_key()] = Method(
    class: self,
    name: name,
    callable: r.to_ref_value(),
    is_macro: true,
    native_signature_known: false,
    native_param_types: @[],
    native_return_type: NIL,
  )
  self.version.inc()

proc add_standard_instance_methods*(class: Class) =
  # Currently no standard methods to add
  discard

#################### Method ######################

proc new_method*(class: Class, name: string, fn: Function): Method =
  let r = new_ref(VkFunction)
  r.fn = fn
  return Method(
    class: class,
    name: name,
    callable: r.to_ref_value(),
    native_signature_known: false,
    native_param_types: @[],
    native_return_type: NIL,
  )

proc clone*(self: Method): Method =
  return Method(
    class: self.class,
    name: self.name,
    callable: self.callable,
    is_macro: self.is_macro,
    native_signature_known: self.native_signature_known,
    native_param_types: self.native_param_types,
    native_return_type: self.native_return_type,
  )

#################### Callable ######################

proc new_callable*(kind: CallableKind, name: string = ""): Callable =
  result = Callable(kind: kind, name: name, arity: 0, flags: {})

  # Set default flags based on kind
  case kind:
  of CkFunction:
    result.flags = {CfEvaluateArgs}
  of CkNativeFunction:
    result.flags = {CfEvaluateArgs, CfIsNative}
  of CkMethod:
    result.flags = {CfEvaluateArgs, CfIsMethod, CfNeedsSelf}
  of CkNativeMethod:
    result.flags = {CfEvaluateArgs, CfIsMethod, CfNeedsSelf, CfIsNative}
  of CkBlock:
    result.flags = {CfEvaluateArgs}

proc get_arity*(matcher: RootMatcher): int =
  # Calculate minimum required arguments
  result = 0
  for child in matcher.children:
    if child.required:
      result.inc()

proc to_callable*(fn: Function): Callable =
  result = new_callable(CkFunction, fn.name)
  result.fn = fn
  result.arity = fn.matcher.get_arity()

proc to_callable*(native_fn: NativeFn, name: string = "", arity: int = 0): Callable =
  result = new_callable(CkNativeFunction, name)
  result.native_fn = native_fn
  result.arity = arity

proc to_callable*(blk: Block): Callable =
  result = new_callable(CkBlock)
  result.block_fn = blk
  result.arity = blk.matcher.get_arity()

proc to_callable*(value: Value): Callable =
  case value.kind:
  of VkFunction:
    return value.ref.fn.to_callable()
  of VkNativeFn:
    return to_callable(value.ref.native_fn)
  of VkBlock:
    return value.ref.block.to_callable()
  else:
    not_allowed("Cannot convert " & $value.kind & " to Callable")
