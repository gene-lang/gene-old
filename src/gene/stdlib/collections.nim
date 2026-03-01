import strutils, tables, algorithm

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
    var mapped_result = new_array_value()
    array_data(mapped_result) = mapped
    mapped_result

  array_class.def_native_method("map", vm_array_map)

  proc vm_array_filter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.filter requires a predicate")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("filter must be called on an array")
    let predicate = get_positional_arg(args, 1, has_keyword_args)
    var filtered_result = new_array_value()
    case predicate.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        var keep: Value
        {.cast(gcsafe).}:
          keep = vm_exec_callable(vm, predicate, @[item])
        if keep.to_bool():
          array_data(filtered_result).add(item)
    else:
      not_allowed("filter predicate must be callable, got " & $predicate.kind)
    filtered_result

  array_class.def_native_method("filter", vm_array_filter, @[("predicate", NIL)], App.app.array_class)

  proc vm_array_reduce(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Array.reduce requires an initial value and a reducer function")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("reduce must be called on an array")
    var accumulator = get_positional_arg(args, 1, has_keyword_args)
    let reducer = get_positional_arg(args, 2, has_keyword_args)
    case reducer.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        {.cast(gcsafe).}:
          accumulator = vm_exec_callable(vm, reducer, @[accumulator, item])
    else:
      not_allowed("reduce reducer must be callable, got " & $reducer.kind)
    accumulator

  array_class.def_native_method("reduce", vm_array_reduce, @[("initial", NIL), ("reducer", NIL)], NIL)

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

  proc vm_array_clear(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.clear requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("clear must be called on an array")
    array_data(arr).setLen(0)
    arr

  array_class.def_native_method("clear", vm_array_clear)

  proc vm_array_pairs(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.pairs requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("pairs must be called on an array")
    var result_ref = new_array_value()
    for i, item in array_data(arr):
      var pair = new_array_value()
      array_data(pair).add(i.int64.to_value())
      array_data(pair).add(item)
      array_data(result_ref).add(pair)
    result_ref

  array_class.def_native_method("pairs", vm_array_pairs)

  proc vm_array_sort(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.sort requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("sort must be called on an array")
    var sorted_result = new_array_value()
    var data = array_data(arr)
    if get_positional_count(arg_count, has_keyword_args) >= 2:
      let comparator = get_positional_arg(args, 1, has_keyword_args)
      var items = newSeq[Value](data.len)
      for i in 0..<data.len:
        items[i] = data[i]
      items.sort(proc(a, b: Value): int =
        {.cast(gcsafe).}:
          let result = vm_exec_callable(vm, comparator, @[a, b])
          if result.kind == VkInt:
            return result.int64.int
          elif result.to_bool():
            return -1
          else:
            return 1
      )
      array_data(sorted_result) = items
    else:
      var items = newSeq[Value](data.len)
      for i in 0..<data.len:
        items[i] = data[i]
      items.sort(proc(a, b: Value): int =
        let sa = display_value(a, true)
        let sb = display_value(b, true)
        cmp(sa, sb)
      )
      array_data(sorted_result) = items
    sorted_result

  array_class.def_native_method("sort", vm_array_sort)

  proc vm_array_reverse(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.reverse requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("reverse must be called on an array")
    var result_ref = new_array_value()
    let data = array_data(arr)
    for i in countdown(data.len - 1, 0):
      array_data(result_ref).add(data[i])
    result_ref

  array_class.def_native_method("reverse", vm_array_reverse)

  proc vm_array_slice(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Array.slice requires start index")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("slice must be called on an array")
    let data = array_data(arr)
    let len = data.len
    var start_idx = get_positional_arg(args, 1, has_keyword_args).to_int().int
    if start_idx < 0:
      start_idx = len + start_idx
    if start_idx < 0:
      start_idx = 0
    var end_idx = if pos_count >= 3:
      var e = get_positional_arg(args, 2, has_keyword_args).to_int().int
      if e < 0:
        e = len + e
      e
    else:
      len
    if end_idx > len:
      end_idx = len
    var result_ref = new_array_value()
    if start_idx < end_idx:
      for i in start_idx..<end_idx:
        array_data(result_ref).add(data[i])
    result_ref

  array_class.def_native_method("slice", vm_array_slice)

  proc vm_array_index_of(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.index_of requires a value")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("index_of must be called on an array")
    let needle = get_positional_arg(args, 1, has_keyword_args)
    for i, item in array_data(arr):
      if item == needle:
        return i.int64.to_value()
    (-1).int64.to_value()

  array_class.def_native_method("index_of", vm_array_index_of)

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
    var result_ref = new_map_value()
    case callback.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key).str.to_value()
        var mapped: Value
        {.cast(gcsafe).}:
          mapped = vm_exec_callable(vm, callback, @[key_val, value])
        map_data(result_ref)[key] = mapped
    else:
      not_allowed("map callback must be callable, got " & $callback.kind)
    result_ref

  map_class.def_native_method("map", vm_map_map, @[("callback", NIL)], App.app.map_class)

  proc vm_map_filter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Map.filter requires a predicate")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("filter must be called on a map")
    let predicate = get_positional_arg(args, 1, has_keyword_args)
    var result_ref = new_map_value()
    case predicate.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key).str.to_value()
        var keep: Value
        {.cast(gcsafe).}:
          keep = vm_exec_callable(vm, predicate, @[key_val, value])
        if keep.to_bool():
          map_data(result_ref)[key] = value
    else:
      not_allowed("filter predicate must be callable, got " & $predicate.kind)
    result_ref

  map_class.def_native_method("filter", vm_map_filter, @[("predicate", NIL)], App.app.map_class)

  proc vm_map_reduce(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 3:
      not_allowed("Map.reduce requires an initial value and a reducer function")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("reduce must be called on a map")
    var accumulator = get_positional_arg(args, 1, has_keyword_args)
    let reducer = get_positional_arg(args, 2, has_keyword_args)
    case reducer.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for key, value in map_data(map_val):
        let key_val = cast[Value](key).str.to_value()
        {.cast(gcsafe).}:
          accumulator = vm_exec_callable(vm, reducer, @[accumulator, key_val, value])
    else:
      not_allowed("reduce reducer must be callable, got " & $reducer.kind)
    accumulator

  map_class.def_native_method("reduce", vm_map_reduce, @[("initial", NIL), ("reducer", NIL)], NIL)

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

  proc vm_map_del(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    let pos_count = get_positional_count(arg_count, has_keyword_args)
    if pos_count < 2:
      not_allowed("Map.del expects at least a key argument")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("del must be called on a map")
    var last_removed = NIL
    for i in 1..<pos_count:
      let key_val = get_positional_arg(args, i, has_keyword_args)
      var key: Key
      case key_val.kind
      of VkString, VkSymbol:
        key = key_val.str.to_key()
      else:
        not_allowed("Map.del key must be a string or symbol")
      if map_data(map_val).hasKey(key):
        last_removed = map_data(map_val)[key]
        map_data(map_val).del(key)
    last_removed

  map_class.def_native_method("del", vm_map_del)

  proc vm_map_merge(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Map.merge expects a map argument")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("merge must be called on a map")
    let other = get_positional_arg(args, 1, has_keyword_args)
    if other.kind == VkMap:
      for key, value in map_data(other):
        map_data(map_val)[key] = value
    else:
      not_allowed("Map.merge argument must be a map")
    map_val

  map_class.def_native_method("merge", vm_map_merge)

  proc vm_map_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.empty requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("empty must be called on a map")
    (map_data(map_val).len == 0).to_value()

  map_class.def_native_method("empty", vm_map_empty)

  proc vm_map_clear(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.clear requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("clear must be called on a map")
    map_data(map_val).clear()
    map_val

  map_class.def_native_method("clear", vm_map_clear)

  proc vm_map_pairs(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.pairs requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("pairs must be called on a map")
    var result_ref = new_array_value()
    for key, value in map_data(map_val):
      var pair = new_array_value()
      let key_val = cast[Value](key)
      array_data(pair).add(key_val.str.to_value())
      array_data(pair).add(value)
      array_data(result_ref).add(pair)
    result_ref

  map_class.def_native_method("pairs", vm_map_pairs)

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
