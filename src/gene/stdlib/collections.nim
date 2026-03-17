import strutils, tables, algorithm

import ../types
import ./classes
import ./json

proc init_collection_classes*(object_class: Class) =
  var r: ptr Reference

  let array_iterator_class = new_class("ArrayIterator")
  array_iterator_class.parent = object_class
  array_iterator_class.def_native_method("to_s", object_to_s_method)
  App.app.gene_ns.ns["ArrayIterator".to_key()] = (block:
    let cls_ref = new_ref(VkClass)
    cls_ref.class = array_iterator_class
    cls_ref.to_ref_value())
  App.app.global_ns.ns["ArrayIterator".to_key()] = App.app.gene_ns.ns["ArrayIterator".to_key()]

  proc array_iterator_iter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                           arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("ArrayIterator.iter requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "ArrayIterator":
      not_allowed("iter must be called on an ArrayIterator")
    iter_val

  proc array_iterator_has_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                               arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("ArrayIterator.has_next requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "ArrayIterator":
      not_allowed("has_next must be called on an ArrayIterator")
    if "array".to_key() notin instance_props(iter_val) or instance_props(iter_val)["array".to_key()].kind != VkArray:
      return FALSE
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    (idx < array_data(instance_props(iter_val)["array".to_key()]).len).to_value()

  proc array_iterator_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                           arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("ArrayIterator.next requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "ArrayIterator":
      not_allowed("next must be called on an ArrayIterator")
    if "array".to_key() notin instance_props(iter_val) or instance_props(iter_val)["array".to_key()].kind != VkArray:
      return NOT_FOUND
    let arr = instance_props(iter_val)["array".to_key()]
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    if idx < 0 or idx >= array_data(arr).len:
      return NOT_FOUND
    instance_props(iter_val)["index".to_key()] = (idx + 1).to_value()
    array_data(arr)[idx]

  proc array_iterator_next_pair(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                                arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("ArrayIterator.next_pair requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "ArrayIterator":
      not_allowed("next_pair must be called on an ArrayIterator")
    if "array".to_key() notin instance_props(iter_val) or instance_props(iter_val)["array".to_key()].kind != VkArray:
      return NOT_FOUND
    let arr = instance_props(iter_val)["array".to_key()]
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    if idx < 0 or idx >= array_data(arr).len:
      return NOT_FOUND
    instance_props(iter_val)["index".to_key()] = (idx + 1).to_value()
    let pair = new_array_value()
    array_data(pair).add(idx.to_value())
    array_data(pair).add(array_data(arr)[idx])
    pair

  array_iterator_class.def_native_method("iter", array_iterator_iter)
  array_iterator_class.def_native_method("has_next", array_iterator_has_next)
  array_iterator_class.def_native_method("next", array_iterator_next)
  array_iterator_class.def_native_method("next_pair", array_iterator_next_pair)

  let map_iterator_class = new_class("MapIterator")
  map_iterator_class.parent = object_class
  map_iterator_class.def_native_method("to_s", object_to_s_method)
  App.app.gene_ns.ns["MapIterator".to_key()] = (block:
    let cls_ref = new_ref(VkClass)
    cls_ref.class = map_iterator_class
    cls_ref.to_ref_value())
  App.app.global_ns.ns["MapIterator".to_key()] = App.app.gene_ns.ns["MapIterator".to_key()]

  proc map_iterator_iter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                         arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("MapIterator.iter requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "MapIterator":
      not_allowed("iter must be called on a MapIterator")
    iter_val

  proc map_iterator_has_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                             arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("MapIterator.has_next requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "MapIterator":
      not_allowed("has_next must be called on a MapIterator")
    if "pairs".to_key() notin instance_props(iter_val) or instance_props(iter_val)["pairs".to_key()].kind != VkArray:
      return FALSE
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    (idx < array_data(instance_props(iter_val)["pairs".to_key()]).len).to_value()

  proc map_iterator_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                         arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("MapIterator.next requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "MapIterator":
      not_allowed("next must be called on a MapIterator")
    if "pairs".to_key() notin instance_props(iter_val) or instance_props(iter_val)["pairs".to_key()].kind != VkArray:
      return NOT_FOUND
    let pairs_val = instance_props(iter_val)["pairs".to_key()]
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    if idx < 0 or idx >= array_data(pairs_val).len:
      return NOT_FOUND
    let pair = array_data(pairs_val)[idx]
    instance_props(iter_val)["index".to_key()] = (idx + 1).to_value()
    if pair.kind != VkArray or array_data(pair).len != 2:
      return NOT_FOUND
    array_data(pair)[1]

  proc map_iterator_next_pair(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                              arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("MapIterator.next_pair requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "MapIterator":
      not_allowed("next_pair must be called on a MapIterator")
    if "pairs".to_key() notin instance_props(iter_val) or instance_props(iter_val)["pairs".to_key()].kind != VkArray:
      return NOT_FOUND
    let pairs_val = instance_props(iter_val)["pairs".to_key()]
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    if idx < 0 or idx >= array_data(pairs_val).len:
      return NOT_FOUND
    let pair = array_data(pairs_val)[idx]
    instance_props(iter_val)["index".to_key()] = (idx + 1).to_value()
    pair

  map_iterator_class.def_native_method("iter", map_iterator_iter)
  map_iterator_class.def_native_method("has_next", map_iterator_has_next)
  map_iterator_class.def_native_method("next", map_iterator_next)
  map_iterator_class.def_native_method("next_pair", map_iterator_next_pair)

  let range_iterator_class = new_class("RangeIterator")
  range_iterator_class.parent = object_class
  range_iterator_class.def_native_method("to_s", object_to_s_method)
  App.app.gene_ns.ns["RangeIterator".to_key()] = (block:
    let cls_ref = new_ref(VkClass)
    cls_ref.class = range_iterator_class
    cls_ref.to_ref_value())
  App.app.global_ns.ns["RangeIterator".to_key()] = App.app.gene_ns.ns["RangeIterator".to_key()]

  proc range_value_at(iter_val: Value, idx: int): Value {.inline.} =
    if "range".to_key() notin instance_props(iter_val) or instance_props(iter_val)["range".to_key()].kind != VkRange:
      return NOT_FOUND
    let range_val = instance_props(iter_val)["range".to_key()]
    let start_val = range_val.ref.range_start.int64
    let end_val = range_val.ref.range_end.int64
    let step_val = if range_val.ref.range_step == NIL: 1'i64 else: range_val.ref.range_step.int64
    if step_val == 0:
      return NOT_FOUND
    let current = start_val + (idx.int64 * step_val)
    if step_val > 0:
      if current > end_val:
        return NOT_FOUND
    else:
      if current < end_val:
        return NOT_FOUND
    current.to_value()

  proc range_iterator_iter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                           arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("RangeIterator.iter requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "RangeIterator":
      not_allowed("iter must be called on a RangeIterator")
    iter_val

  proc range_iterator_has_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                               arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("RangeIterator.has_next requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "RangeIterator":
      not_allowed("has_next must be called on a RangeIterator")
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    (range_value_at(iter_val, idx) != NOT_FOUND).to_value()

  proc range_iterator_next(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                           arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("RangeIterator.next requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "RangeIterator":
      not_allowed("next must be called on a RangeIterator")
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    let current = range_value_at(iter_val, idx)
    if current == NOT_FOUND:
      return NOT_FOUND
    instance_props(iter_val)["index".to_key()] = (idx + 1).to_value()
    current

  proc range_iterator_next_pair(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value],
                                arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("RangeIterator.next_pair requires self")
    let iter_val = get_positional_arg(args, 0, has_keyword_args)
    if iter_val.kind != VkInstance or iter_val.instance_class == nil or iter_val.instance_class.name != "RangeIterator":
      not_allowed("next_pair must be called on a RangeIterator")
    let idx =
      if "index".to_key() in instance_props(iter_val) and instance_props(iter_val)["index".to_key()].kind == VkInt:
        instance_props(iter_val)["index".to_key()].int64.int
      else:
        0
    let current = range_value_at(iter_val, idx)
    if current == NOT_FOUND:
      return NOT_FOUND
    instance_props(iter_val)["index".to_key()] = (idx + 1).to_value()
    let pair = new_array_value()
    array_data(pair).add(idx.to_value())
    array_data(pair).add(current)
    pair

  range_iterator_class.def_native_method("iter", range_iterator_iter)
  range_iterator_class.def_native_method("has_next", range_iterator_has_next)
  range_iterator_class.def_native_method("next", range_iterator_next)
  range_iterator_class.def_native_method("next_pair", range_iterator_next_pair)

  let range_class = new_class("Range")
  range_class.parent = object_class
  range_class.def_native_method("to_s", object_to_s_method)
  r = new_ref(VkClass)
  r.class = range_class
  App.app.range_class = r.to_ref_value()
  App.app.gene_ns.ns["Range".to_key()] = App.app.range_class
  App.app.global_ns.ns["Range".to_key()] = App.app.range_class

  proc vm_range_iter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Range.iter requires self")
    let range_val = get_positional_arg(args, 0, has_keyword_args)
    if range_val.kind != VkRange:
      not_allowed("iter must be called on a range")
    let iterator_class_val = App.app.gene_ns.ns["RangeIterator".to_key()]
    if iterator_class_val.kind != VkClass or iterator_class_val.ref.class == nil:
      not_allowed("RangeIterator class is not initialized")
    let iter_val = new_instance_value(iterator_class_val.ref.class)
    instance_props(iter_val)["range".to_key()] = range_val
    instance_props(iter_val)["index".to_key()] = 0.to_value()
    iter_val

  range_class.def_native_method("iter", vm_range_iter)

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
      ensure_mutable_array(arr, "append to")
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

  proc vm_array_iter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.iter requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("iter must be called on an array")
    let iterator_class_val = App.app.gene_ns.ns["ArrayIterator".to_key()]
    if iterator_class_val.kind != VkClass or iterator_class_val.ref.class == nil:
      not_allowed("ArrayIterator class is not initialized")
    let iter_val = new_instance_value(iterator_class_val.ref.class)
    instance_props(iter_val)["array".to_key()] = arr
    instance_props(iter_val)["index".to_key()] = 0.to_value()
    iter_val

  array_class.def_native_method("iter", vm_array_iter)

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
    ensure_mutable_array(arr, "set item on")
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
    ensure_mutable_array(arr, "delete from")
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
  array_class.def_native_method("empty?", vm_array_empty)

  proc vm_array_not_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.not_empty? requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("not_empty? must be called on an array")
    (array_data(arr).len != 0).to_value()

  array_class.def_native_method("not_empty?", vm_array_not_empty)

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

  proc vm_array_push(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.push requires a value")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("push must be called on an array")
    let value = get_positional_arg(args, 1, has_keyword_args)
    ensure_mutable_array(arr, "push to")
    array_data(arr).add(value)
    array_data(arr).len.to_value()

  array_class.def_native_method("push", vm_array_push)

  proc vm_array_pop(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.pop requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("pop must be called on an array")
    let len = array_data(arr).len
    if len == 0:
      return NIL
    ensure_mutable_array(arr, "pop from")
    result = array_data(arr)[len - 1]
    array_data(arr).setLen(len - 1)

  array_class.def_native_method("pop", vm_array_pop)

  proc vm_array_find(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.find requires a predicate")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("find must be called on an array")
    let predicate = get_positional_arg(args, 1, has_keyword_args)
    case predicate.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        var matched: Value
        {.cast(gcsafe).}:
          matched = vm_exec_callable(vm, predicate, @[item])
        if matched.to_bool():
          return item
      return NIL
    else:
      not_allowed("find predicate must be callable, got " & $predicate.kind)

  array_class.def_native_method("find", vm_array_find)

  proc vm_array_any(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.any requires a predicate")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("any must be called on an array")
    let predicate = get_positional_arg(args, 1, has_keyword_args)
    case predicate.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        var matched: Value
        {.cast(gcsafe).}:
          matched = vm_exec_callable(vm, predicate, @[item])
        if matched.to_bool():
          return TRUE
      return FALSE
    else:
      not_allowed("any predicate must be callable, got " & $predicate.kind)

  array_class.def_native_method("any", vm_array_any)

  proc vm_array_all(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.all requires a predicate")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("all must be called on an array")
    let predicate = get_positional_arg(args, 1, has_keyword_args)
    case predicate.kind
    of VkFunction, VkNativeFn, VkNativeMethod, VkBoundMethod, VkBlock:
      for item in array_data(arr):
        var matched: Value
        {.cast(gcsafe).}:
          matched = vm_exec_callable(vm, predicate, @[item])
        if not matched.to_bool():
          return FALSE
      return TRUE
    else:
      not_allowed("all predicate must be callable, got " & $predicate.kind)

  array_class.def_native_method("all", vm_array_all)

  proc vm_array_zip(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.zip requires another array")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("zip must be called on an array")
    let other = get_positional_arg(args, 1, has_keyword_args)
    if other.kind != VkArray:
      not_allowed("zip argument must be an array")
    let len = min(array_data(arr).len, array_data(other).len)
    var result_ref = new_array_value()
    for i in 0..<len:
      var pair = new_array_value()
      array_data(pair).add(array_data(arr)[i])
      array_data(pair).add(array_data(other)[i])
      array_data(result_ref).add(pair)
    result_ref

  array_class.def_native_method("zip", vm_array_zip)

  proc vm_array_take(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.take requires count")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("take must be called on an array")
    let count_val = get_positional_arg(args, 1, has_keyword_args)
    if count_val.kind != VkInt:
      not_allowed("take count must be an integer")
    let data = array_data(arr)
    var count = count_val.int64.int
    if count < 0:
      count = 0
    if count > data.len:
      count = data.len
    var result_ref = new_array_value()
    for i in 0..<count:
      array_data(result_ref).add(data[i])
    result_ref

  array_class.def_native_method("take", vm_array_take)

  proc vm_array_skip(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 2:
      not_allowed("Array.skip requires count")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("skip must be called on an array")
    let count_val = get_positional_arg(args, 1, has_keyword_args)
    if count_val.kind != VkInt:
      not_allowed("skip count must be an integer")
    let data = array_data(arr)
    var count = count_val.int64.int
    if count < 0:
      count = 0
    if count > data.len:
      count = data.len
    var result_ref = new_array_value()
    for i in count..<data.len:
      array_data(result_ref).add(data[i])
    result_ref

  array_class.def_native_method("skip", vm_array_skip)

  proc vm_array_to_map(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Array.to_map requires self")
    let arr = get_positional_arg(args, 0, has_keyword_args)
    if arr.kind != VkArray:
      not_allowed("to_map must be called on an array")

    var result_ref = new_map_value()
    for item in array_data(arr):
      if item.kind != VkArray:
        not_allowed("to_map expects [key value] pairs")
      let pair = array_data(item)
      if pair.len != 2:
        not_allowed("to_map expects [key value] pairs")
      let key_val = pair[0]
      let key = case key_val.kind
        of VkString, VkSymbol: key_val.str.to_key()
        of VkInt: ($key_val.int64).to_key()
        else:
          not_allowed("to_map key must be string, symbol, or int")
          "".to_key()
      map_data(result_ref)[key] = pair[1]
    result_ref

  array_class.def_native_method("to_map", vm_array_to_map)

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
    ensure_mutable_array(arr, "clear")
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
          let compare_result = vm_exec_callable(vm, comparator, @[a, b])
          if compare_result.kind == VkInt:
            return compare_result.int64.int
          elif compare_result.to_bool():
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
    ensure_mutable_map(map, "set item on")
    map_data(map)[key] = value
    return map

  map_class.def_native_method("set", vm_map_set)

  proc vm_map_immutable(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.immutable? requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("immutable? must be called on a map")
    map_is_frozen(map_val).to_value()

  map_class.def_native_method("immutable?", vm_map_immutable, @[], App.app.bool_class)

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

  proc vm_map_iter(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe, nimcall.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.iter requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("iter must be called on a map")
    let iterator_class_val = App.app.gene_ns.ns["MapIterator".to_key()]
    if iterator_class_val.kind != VkClass or iterator_class_val.ref.class == nil:
      not_allowed("MapIterator class is not initialized")
    let iter_val = new_instance_value(iterator_class_val.ref.class)
    let snapshot = new_array_value()
    for key, value in map_data(map_val):
      let pair = new_array_value()
      array_data(pair).add(cast[Value](key))
      array_data(pair).add(value)
      array_data(snapshot).add(pair)
    instance_props(iter_val)["pairs".to_key()] = snapshot
    instance_props(iter_val)["index".to_key()] = 0.to_value()
    iter_val

  map_class.def_native_method("iter", vm_map_iter)

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
    ensure_mutable_map(map_val, "delete from")
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
    ensure_mutable_map(map_val, "merge into")
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
  map_class.def_native_method("empty?", vm_map_empty)

  proc vm_map_not_empty(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.not_empty? requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("not_empty? must be called on a map")
    (map_data(map_val).len != 0).to_value()

  map_class.def_native_method("not_empty?", vm_map_not_empty)

  proc vm_map_clear(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if get_positional_count(arg_count, has_keyword_args) < 1:
      not_allowed("Map.clear requires self")
    let map_val = get_positional_arg(args, 0, has_keyword_args)
    if map_val.kind != VkMap:
      not_allowed("clear must be called on a map")
    ensure_mutable_map(map_val, "clear")
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
