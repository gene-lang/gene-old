import tables

import ../types
import ./classes

proc init_selector_class*(object_class: Class) =
  var r: ptr Reference
  let selector_class = new_class("Selector")
  selector_class.parent = object_class
  selector_class.def_native_method("to_s", object_to_s_method)

  proc selector_call(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
    if arg_count < 2:
      not_allowed("Selector.call expects a target value")

    let selector_val = get_positional_arg(args, 0, has_keyword_args)
    if selector_val.kind != VkSelector:
      not_allowed("Selector.call must be invoked on a selector")

    let target = get_positional_arg(args, 1, has_keyword_args)
    let has_default = arg_count >= 3
    let default_value = if has_default: get_positional_arg(args, 2, has_keyword_args) else: NIL

    type SelectorMode = enum
      SmValue
      SmValues
      SmEntries

    var mode = SmValue
    var current = target
    var values_stream: seq[Value] = @[]
    var entries_stream: seq[(Key, Value)] = @[]

    proc is_selector_callable(seg: Value): bool {.inline.} =
      seg.kind in {VkFunction, VkNativeFn, VkBlock, VkBoundMethod, VkNativeMethod}

    proc key_to_symbol_value(k: Key): Value {.inline.} =
      cast[Value](k)

    proc collect_values(values: seq[Value]): Value =
      var r = new_array_value()
      for v in values:
        array_data(r).add(v)
      r

    proc collect_pairs(entries: seq[(Key, Value)]): Value =
      var r = new_array_value()
      for (k, v) in entries:
        var pair = new_array_value()
        array_data(pair).add(key_to_symbol_value(k))
        array_data(pair).add(v)
        array_data(r).add(pair)
      r

    proc collect_entries_to_map(entries: seq[(Key, Value)]): Value =
      var r = new_map_value()
      for (k, v) in entries:
        if v != VOID:
          map_data(r)[k] = v
      r

    proc call_native_value_method(target: Value, method_name: string, call_args: seq[Value] = @[]): tuple[found: bool, value: Value] =
      let class_val = value_class_value(target)
      if class_val.kind != VkClass or class_val.ref.class == nil:
        return (false, NIL)
      let meth = class_val.ref.class.get_method(method_name)
      if meth == nil or meth.callable.kind != VkNativeFn:
        return (false, NIL)
      var args = newSeq[Value](call_args.len + 1)
      args[0] = target
      for i, arg in call_args:
        args[i + 1] = arg
      (true, call_native_fn(meth.callable.ref.native_fn, vm, args))

    proc parse_pair_value(pair_val: Value): (Key, Value) =
      if pair_val.kind != VkArray:
        not_allowed("Entry transform must return [key value], got " & $pair_val.kind)
      let items = array_data(pair_val)
      if items.len != 2:
        not_allowed("Entry transform must return [key value]")
      let key_val = items[0]
      let key = case key_val.kind:
        of VkString, VkSymbol: key_val.str.to_key()
        of VkInt: ($key_val.int64).to_key()
        else:
          not_allowed("Entry key must be string/symbol/int, got " & $key_val.kind)
          "".to_key()
      (key, items[1])

    proc expand_iterable_values(v: Value): seq[Value] =
      let (iter_found, iter_val) = call_native_value_method(v, "iter")
      if not iter_found:
        return @[]
      while true:
        let (next_found, next_val) = call_native_value_method(iter_val, "next")
        if not next_found or next_val == NOT_FOUND:
          break
        if next_val != VOID:
          result.add(next_val)

    proc expand_iterable_entries(v: Value): seq[(Key, Value)] =
      let (iter_found, iter_val) = call_native_value_method(v, "iter")
      if not iter_found:
        return @[]
      while true:
        let (next_found, next_val) = call_native_value_method(iter_val, "next_pair")
        if not next_found or next_val == NOT_FOUND:
          break
        let (key, value) = parse_pair_value(next_val)
        if value != VOID:
          result.add((key, value))

    proc expand_values(v: Value): seq[Value] =
      if v == VOID or v == NIL:
        return @[]
      if has_custom_materializer(v):
        return expand_values(materialize_custom(v))
      case v.kind:
      of VkArray:
        result = @[]
        for item in array_data(v):
          if item != VOID:
            result.add(item)
      of VkGene:
        result = @[]
        for child in v.gene.children:
          if child != VOID:
            result.add(child)
      else:
        result = expand_iterable_values(v)

    proc expand_entries(v: Value): seq[(Key, Value)] =
      if v == VOID or v == NIL:
        return @[]
      if has_custom_materializer(v):
        return expand_entries(materialize_custom(v))
      result = @[]
      case v.kind:
      of VkMap:
        for k, item in map_data(v):
          if item != VOID:
            result.add((k, item))
      of VkGene:
        for k, item in v.gene.props:
          if item != VOID:
            result.add((k, item))
      of VkNamespace:
        for k, item in v.ref.ns.members:
          if item != VOID:
            result.add((k, item))
      of VkClass:
        for k, item in v.ref.class.ns.members:
          if item != VOID:
            result.add((k, item))
      of VkInstance:
        for k, item in instance_props(v):
          if item != VOID:
            result.add((k, item))
      else:
        result = expand_iterable_entries(v)

    proc apply_lookup(base: Value, seg: Value): Value =
      if base == VOID or base == NIL:
        return VOID
      if has_custom_materializer(base):
        return apply_lookup(materialize_custom(base), seg)

      case seg.kind:
      of VkString, VkSymbol:
        let key = seg.str.to_key()
        case base.kind:
        of VkMap:
          return map_data(base).getOrDefault(key, VOID)
        of VkGene:
          if key in base.gene.props:
            return base.gene.props[key]
          return VOID
        of VkNamespace:
          if base.ref.ns.has_key(key):
            return base.ref.ns[key]
          return VOID
        of VkClass:
          if base.ref.class.ns.has_key(key):
            return base.ref.class.ns[key]
          return VOID
        of VkInstance:
          return instance_props(base).getOrDefault(key, VOID)
        else:
          return VOID
      of VkInt:
        let idx64 = seg.int64
        case base.kind:
        of VkArray:
          let arr_len = array_data(base).len.int64
          var resolved = idx64
          if resolved < 0:
            resolved = arr_len + resolved
          if resolved >= 0 and resolved < arr_len:
            return array_data(base)[resolved.int]
          return VOID
        of VkGene:
          let children_len = base.gene.children.len.int64
          var resolved = idx64
          if resolved < 0:
            resolved = children_len + resolved
          if resolved >= 0 and resolved < children_len:
            return base.gene.children[resolved.int]
          return VOID
        else:
          return VOID
      else:
        not_allowed("Invalid selector segment type: " & $seg.kind)
        return VOID

    for seg in selector_val.ref.selector_path:
      if seg.kind == VkSymbol and seg.str == "!":
        case mode:
        of SmValue:
          if current == VOID:
            not_allowed("Selector did not match (VOID)")
          if current == NIL:
            not_allowed("Selector matched but value is nil")
        of SmValues:
          if values_stream.len == 0:
            not_allowed("Selector did not match (empty)")
          for v in values_stream:
            if v == VOID:
              not_allowed("Selector did not match (VOID)")
            if v == NIL:
              not_allowed("Selector matched but value is nil")
        of SmEntries:
          if entries_stream.len == 0:
            not_allowed("Selector did not match (empty)")
          for (_, v) in entries_stream:
            if v == VOID:
              not_allowed("Selector did not match (VOID)")
            if v == NIL:
              not_allowed("Selector matched but value is nil")
        continue

      if seg.kind == VkSymbol:
        case seg.str:
        of "*":
          case mode:
          of SmValue:
            values_stream = expand_values(current)
          of SmValues:
            var next: seq[Value] = @[]
            for v in values_stream:
              for item in expand_values(v):
                next.add(item)
            values_stream = next
          of SmEntries:
            var next: seq[Value] = @[]
            for (_, v) in entries_stream:
              for item in expand_values(v):
                next.add(item)
            values_stream = next
          entries_stream = @[]
          current = VOID
          mode = SmValues
          continue
        of "**":
          case mode:
          of SmValue:
            entries_stream = expand_entries(current)
          of SmValues:
            var next: seq[(Key, Value)] = @[]
            for v in values_stream:
              for item in expand_entries(v):
                next.add(item)
            entries_stream = next
          of SmEntries:
            var next: seq[(Key, Value)] = @[]
            for (_, v) in entries_stream:
              for item in expand_entries(v):
                next.add(item)
            entries_stream = next
          values_stream = @[]
          current = VOID
          mode = SmEntries
          continue
        of "@":
          case mode:
          of SmValue:
            if current == VOID:
              current = new_array_value()
            else:
              current = collect_values(@[current])
          of SmValues:
            current = collect_values(values_stream)
          of SmEntries:
            current = collect_pairs(entries_stream)
          values_stream = @[]
          entries_stream = @[]
          mode = SmValue
          continue
        of "@@":
          if mode != SmEntries:
            not_allowed("@@ requires an entry stream (use ** to expand entries first)")
          current = collect_entries_to_map(entries_stream)
          values_stream = @[]
          entries_stream = @[]
          mode = SmValue
          continue
        else:
          discard

      if is_selector_callable(seg):
        case mode:
        of SmValue:
          if current == VOID:
            discard
          else:
            var updated: Value = NIL
            {.cast(gcsafe).}:
              updated = vm_exec_callable(vm, seg, @[current])
            current = updated
        of SmValues:
          var next: seq[Value] = @[]
          for v in values_stream:
            var updated: Value = NIL
            {.cast(gcsafe).}:
              updated = vm_exec_callable(vm, seg, @[v])
            if updated != VOID:
              next.add(updated)
          values_stream = next
        of SmEntries:
          var next: seq[(Key, Value)] = @[]
          for (k, v) in entries_stream:
            var updated: Value = NIL
            {.cast(gcsafe).}:
              updated = vm_exec_callable(vm, seg, @[key_to_symbol_value(k), v])
            if updated == VOID:
              continue
            if updated.kind == VkArray:
              let (new_k, new_v) = parse_pair_value(updated)
              if new_v != VOID:
                next.add((new_k, new_v))
            else:
              if updated != VOID:
                next.add((k, updated))
          entries_stream = next
        continue

      case mode:
      of SmValue:
        current = apply_lookup(current, seg)
      of SmValues:
        var next: seq[Value] = @[]
        for v in values_stream:
          let r = apply_lookup(v, seg)
          if r != VOID:
            next.add(r)
        values_stream = next
      of SmEntries:
        var next: seq[(Key, Value)] = @[]
        for (k, v) in entries_stream:
          let r = apply_lookup(v, seg)
          if r != VOID:
            next.add((k, r))
        entries_stream = next

    case mode:
    of SmValue:
      if current == VOID and has_default:
        return default_value
      return current
    of SmValues:
      if values_stream.len == 0 and has_default:
        return default_value
      return collect_values(values_stream)
    of SmEntries:
      if entries_stream.len == 0 and has_default:
        return default_value
      return collect_pairs(entries_stream)

  selector_class.def_native_method("call", selector_call)

  r = new_ref(VkClass)
  r.class = selector_class
  App.app.selector_class = r.to_ref_value()
  if App.app.gene_ns.kind == VkNamespace:
    App.app.gene_ns.ref.ns["Selector".to_key()] = App.app.selector_class
