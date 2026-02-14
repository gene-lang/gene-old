import strutils, tables

import ../types
import ./classes
import ./json

proc init_collection_classes*(object_class: Class) =
  var r: ptr Reference
  let array_class = new_class("Array")
  array_class.parent = object_class
  array_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = array_class
  App.app.array_class = r.to_ref_value()
  App.app.gene_ns.ns["Array".to_key()] = App.app.array_class
  App.app.global_ns.ns["Array".to_key()] = App.app.array_class

  proc vm_array_add(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let arr = get_positional_arg(args, 0, has_keyword_args)
    let value = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: NIL
    if arr.kind == VkArray:
      array_data(arr).add(value)
    return arr

  array_class.def_native_method("add", vm_array_add, @[("value", NIL)], App.app.array_class)
  array_class.def_native_method("append", vm_array_add, @[("value", NIL)], App.app.array_class)

  proc vm_array_size(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind == VkArray:
      return array_data(arr).len.to_value()
    return 0.to_value()

  array_class.def_native_method("size", vm_array_size, @[], App.app.int_class)
  array_class.def_native_method("length", vm_array_size, @[], App.app.int_class)

  proc vm_array_first(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("first must be called on an array")
    if array_data(arr).len == 0:
      return NIL
    array_data(arr)[0]

  proc vm_array_last(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("last must be called on an array")
    if array_data(arr).len == 0:
      return NIL
    let data = array_data(arr)
    data[data.len - 1]

  array_class.def_native_method("first", vm_array_first, @[], NIL)
  array_class.def_native_method("last", vm_array_last, @[], NIL)

  proc vm_array_get(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    let arr = get_positional_arg(args, 0, has_keyword_args)
    let index = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: 0.to_value()
    if arr.kind == VkArray and index.kind == VkInt:
      let idx = index.int64.int
      if idx >= 0 and idx < array_data(arr).len:
        return array_data(arr)[idx]
    return NIL

  array_class.def_native_method("get", vm_array_get)

  proc normalize_index(len: int, raw: int64): int {.inline.} =
    var idx = raw.int
    if idx < 0:
      idx = len + idx
    idx

  proc vm_array_set(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Array.set requires index and value")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("set must be called on an array")
    let index_val = get_positional_arg(args, 1, has_keyword_args)
    if index_val.kind != VkInt:
      not_allowed("set index must be an integer")
    let len = array_data(arr).len
    var idx = normalize_index(len, index_val.int64)
    if idx < 0 or idx >= len:
      not_allowed("set index out of bounds")
    let value = get_positional_arg(args, 2, has_keyword_args)
    array_data(arr)[idx] = value
    arr

  array_class.def_native_method("set", vm_array_set)

  proc vm_array_del(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.del requires index")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("del must be called on an array")
    let index_val = get_positional_arg(args, 1, has_keyword_args)
    if index_val.kind != VkInt:
      not_allowed("del index must be an integer")
    var arr_data = array_data(arr)
    let len = arr_data.len
    var idx = normalize_index(len, index_val.int64)
    if idx < 0 or idx >= len:
      not_allowed("del index out of bounds")
    let removed = arr_data[idx]
    arr_data.delete(idx)
    removed

  array_class.def_native_method("del", vm_array_del)

  proc vm_array_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.empty requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("empty must be called on an array")
    (array_data(arr).len == 0).to_value()

  array_class.def_native_method("empty", vm_array_empty)

  proc vm_array_contains(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.contains requires value")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("contains must be called on an array")
    let needle = get_positional_arg(args, 1, has_keyword_args)
    for item in array_data(arr):
      if item == needle:
        return TRUE
    FALSE

  array_class.def_native_method("contains", vm_array_contains)

  proc vm_array_to_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.to_json requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("to_json must be called on an array")
    value_to_json(arr).to_value()

  array_class.def_native_method("to_json", vm_array_to_json)

  proc vm_array_each(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.each requires a function")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("each must be called on an array")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    case callback.kind
    of VkFunction:
      for item in array_data(arr):
        {.cast(gcsafe).}:
          discard vm_exec_callable(vm, callback, @[item])
    of VkNativeFn:
      for item in array_data(arr):
        {.cast(gcsafe).}:
          discard call_native_fn(callback.ref.native_fn, vm, [item])
    else:
      not_allowed("each callback must be a function")
    arr

  array_class.def_native_method("each", vm_array_each)

  proc vm_array_map(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.map requires a function")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("map must be called on an array")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    var mapped: seq[Value] = @[]
    case callback.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        var mapped_value: Value
        {.cast(gcsafe).}:
          mapped_value = vm_exec_callable(vm, callback, @[item])
        mapped.add(mapped_value)
    else:
      not_allowed("map callback must be a function, got " & $callback.kind)
    var result = new_array_value()
    array_data(result) = mapped
    result

  array_class.def_native_method("map", vm_array_map)

  proc vm_array_join(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 1:
      not_allowed("Array.join requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("join must be called on an array")
    let sep = if pos_count > 1:
      let sep_arg = get_positional_arg(args, 1, has_keyword_args)
      if sep_arg.kind != VkString:
        not_allowed("Array.join separator must be a string")
      sep_arg.str
    else:
      ""
    var parts: seq[string] = @[]
    for item in array_data(arr):
      parts.add(display_value(item, true))
    parts.join(sep).to_value()

  array_class.def_native_method("join", vm_array_join)

  let map_class = new_class("Map")
  map_class.parent = object_class
  map_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = map_class
  App.app.map_class = r.to_ref_value()
  App.app.gene_ns.ns["Map".to_key()] = App.app.map_class
  App.app.global_ns.ns["Map".to_key()] = App.app.map_class

  proc vm_map_contains(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let map = get_positional_arg(args, 0, has_keyword_args)
    let key = if arg_count > 1: get_positional_arg(args, 1, has_keyword_args) else: NIL
    if map.kind == VkMap and key.kind == VkString:
      return map_data(map).hasKey(key.str.to_key()).to_value()
    elif map.kind == VkMap and key.kind == VkSymbol:
      return map_data(map).hasKey(key.str.to_key()).to_value()
    return false.to_value()

  proc vm_map_get(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value =
    if arg_count < 2:
      not_allowed("Map.get expects at least a key argument")

    let map = get_positional_arg(args, 0, has_keyword_args)
    if map.kind != VkMap:
      not_allowed("Map.get must be called on a map")

    let key_val = get_positional_arg(args, 1, has_keyword_args)
    var key: Key

    case key_val.kind
    of VkString:
      key = key_val.str.to_key()
    of VkSymbol:
      key = key_val.str.to_key()
    else:
      not_allowed("Map.get key must be a string or symbol")

    if map_data(map).hasKey(key):
      return map_data(map)[key]

    if arg_count >= 3:
      return get_positional_arg(args, 2, has_keyword_args)

    return NIL

  map_class.def_native_method("get", vm_map_get)

  proc vm_map_set(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Map.set expects key and value arguments")

    let map = get_positional_arg(args, 0, has_keyword_args)
    if map.kind != VkMap:
      not_allowed("Map.set must be called on a map")

    let key_val = get_positional_arg(args, 1, has_keyword_args)
    var key: Key

    case key_val.kind
    of VkString:
      key = key_val.str.to_key()
    of VkSymbol:
      key = key_val.str.to_key()
    else:
      not_allowed("Map.set key must be a string or symbol")

    let value = get_positional_arg(args, 2, has_keyword_args)
    map_data(map)[key] = value
    return map

  map_class.def_native_method("set", vm_map_set)

  map_class.def_native_method("contains", vm_map_contains)
  map_class.def_native_method("has", vm_map_contains, @[("key", NIL)], App.app.bool_class)

  proc vm_map_size(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.size requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("size must be called on a map")
    map_data(map_val).len.to_value()

  map_class.def_native_method("size", vm_map_size, @[], App.app.int_class)

  proc vm_map_keys(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.keys requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("keys must be called on a map")
    var result_ref = new_array_value()
    for key, _ in map_data(map_val):
      let key_val = cast[Value](key)
      array_data(result_ref).add(key_val.str.to_value())
    result_ref

  map_class.def_native_method("keys", vm_map_keys, @[], App.app.array_class)

  proc vm_map_values(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.values requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("values must be called on a map")
    var result_ref = new_array_value()
    for _, value in map_data(map_val):
      array_data(result_ref).add(value)
    result_ref

  map_class.def_native_method("values", vm_map_values, @[], App.app.array_class)

  proc vm_map_map(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Map.map requires a function")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("map must be called on a map")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    var result_ref = new_array_value()
    case callback.kind
    of VkFunction:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          let mapped = vm_exec_callable(vm, callback, @[key_val, value])
          array_data(result_ref).add(mapped)
    of VkNativeFn:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          let mapped = call_native_fn(callback.ref.native_fn, vm, [key_val, value])
          array_data(result_ref).add(mapped)
    else:
      not_allowed("map callback must be a function")
    result_ref

  map_class.def_native_method("map", vm_map_map)

  proc vm_map_each(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Map.each requires a function")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("each must be called on a map")
    let callback = get_positional_arg(args, 1, has_keyword_args)
    case callback.kind
    of VkFunction:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          discard vm_exec_callable(vm, callback, @[key_val.str.to_value(), value])
    of VkNativeFn:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key)
        {.cast(gcsafe).}:
          discard call_native_fn(callback.ref.native_fn, vm, [key_val.str.to_value(), value])
    else:
      not_allowed("each callback must be a function")
    map_val

  map_class.def_native_method("each", vm_map_each)

  proc vm_map_to_json(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.to_json requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("to_json must be called on a map")
    value_to_json(map_val).to_value()

  map_class.def_native_method("to_json", vm_map_to_json)

proc init_set_class*(object_class: Class) =
  var r: ptr Reference
  let set_class = new_class("Set")
  set_class.parent = object_class
  set_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = set_class
  App.app.set_class = r.to_ref_value()
  App.app.gene_ns.ns["Set".to_key()] = App.app.set_class
  App.app.global_ns.ns["Set".to_key()] = App.app.set_class
