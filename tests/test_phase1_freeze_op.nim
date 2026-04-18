import unittest, tables

import helpers
import ../src/gene/types except Exception
import ../src/gene/stdlib/freeze
import ../src/gene/vm

proc flags_of(v: Value): uint8 =
  let u = cast[uint64](v)
  if (u and NAN_MASK) != NAN_MASK:
    return 0'u8

  let tag = u and 0xFFFF_0000_0000_0000u64
  case tag
  of ARRAY_TAG:
    let arr = cast[ptr ArrayObj](u and PAYLOAD_MASK)
    if arr == nil: 0'u8 else: arr.flags
  of MAP_TAG:
    let m = cast[ptr MapObj](u and PAYLOAD_MASK)
    if m == nil: 0'u8 else: m.flags
  of INSTANCE_TAG:
    let inst = cast[ptr InstanceObj](u and PAYLOAD_MASK)
    if inst == nil: 0'u8 else: inst.flags
  of GENE_TAG:
    let g = cast[ptr Gene](u and PAYLOAD_MASK)
    if g == nil: 0'u8 else: g.flags
  of STRING_TAG:
    let s = cast[ptr String](u and PAYLOAD_MASK)
    if s == nil: 0'u8 else: s.flags
  of REF_TAG:
    let r = cast[ptr Reference](u and PAYLOAD_MASK)
    if r == nil: 0'u8 else: r.flags
  else:
    0'u8

proc clear_flags(v: Value) =
  let u = cast[uint64](v)
  if (u and NAN_MASK) != NAN_MASK:
    return

  let tag = u and 0xFFFF_0000_0000_0000u64
  case tag
  of ARRAY_TAG:
    let arr = cast[ptr ArrayObj](u and PAYLOAD_MASK)
    if arr != nil:
      arr.flags = 0
  of MAP_TAG:
    let m = cast[ptr MapObj](u and PAYLOAD_MASK)
    if m != nil:
      m.flags = 0
  of INSTANCE_TAG:
    let inst = cast[ptr InstanceObj](u and PAYLOAD_MASK)
    if inst != nil:
      inst.flags = 0
  of GENE_TAG:
    let g = cast[ptr Gene](u and PAYLOAD_MASK)
    if g != nil:
      g.flags = 0
  of STRING_TAG:
    let s = cast[ptr String](u and PAYLOAD_MASK)
    if s != nil:
      s.flags = 0
  of REF_TAG:
    let r = cast[ptr Reference](u and PAYLOAD_MASK)
    if r != nil:
      r.flags = 0
  else:
    discard

proc expect_frozen_flag(v: Value) =
  if isManaged(v):
    check (flags_of(v) and DeepFrozenBit) != 0
    check (flags_of(v) and SharedBit) != 0
  check deep_frozen(v)

suite "Phase 1 freeze op":
  test "freeze_value marks every reachable MVP managed value":
    var inner_array = new_array_value(2.to_value(), "phase1-string".to_value())
    var inner_map = new_map_value({"leaf".to_key(): inner_array}.toTable())
    var hash_map = new_hash_map_value(@["key".to_value(), inner_map])
    var bytes = new_bytes_value(@[1'u8, 2, 3, 4, 5, 6, 7])
    var gene = new_gene_value("Widget".to_symbol_value())
    gene.gene.props["payload".to_key()] = hash_map
    gene.gene.children.add(bytes)

    for value in [inner_array, inner_map, hash_map, bytes, gene]:
      clear_flags(value)

    let frozen = freeze_value(gene)

    check frozen == gene
    expect_frozen_flag(gene)
    expect_frozen_flag(hash_map)
    expect_frozen_flag(inner_map)
    expect_frozen_flag(inner_array)
    expect_frozen_flag(bytes)
    expect_frozen_flag(array_data(inner_array)[1])

  test "freeze builtin is registered through stdlib init":
    init_all()
    let result = VM.exec("(freeze [(freeze [1]) {^a [2 3]}])", "phase1_freeze_builtin")
    check result.kind == VkArray
    expect_frozen_flag(result)
    expect_frozen_flag(array_data(result)[0])
    expect_frozen_flag(map_data(array_data(result)[1])["a".to_key()])

  test "deep recursion across arrays, maps, and genes stays in scope":
    var leaf = new_array_value(3.to_value(), 4.to_value())
    var mid_map = new_map_value({"items".to_key(): leaf}.toTable())
    var child_gene = new_gene_value("Node".to_symbol_value())
    child_gene.gene.children.add(mid_map)
    var root = new_array_value(child_gene)

    discard freeze_value(root)

    expect_frozen_flag(root)
    expect_frozen_flag(child_gene)
    expect_frozen_flag(mid_map)
    expect_frozen_flag(leaf)

  test "non MVP values raise typed errors with offending kind and path":
    var caught = false
    try:
      discard freeze_value(new_ref(VkNativeFn).to_ref_value())
      fail()
    except FreezeScopeError as err:
      caught = true
      check err.offending_kind == VkNativeFn
      check err.path == "/"
    check caught

  test "validation failures are atomic and do not set flags":
    var nested = new_map_value({"ok".to_key(): new_array_value(1.to_value())}.toTable())
    var root = new_array_value(nested, new_ref(VkClass).to_ref_value())
    clear_flags(nested)
    clear_flags(root)

    var caught = false
    try:
      discard freeze_value(root)
      fail()
    except FreezeScopeError as err:
      caught = true
      check err.offending_kind == VkClass
      check err.path == "/[1]"
    check caught
    check flags_of(root) == 0'u8
    check flags_of(nested) == 0'u8
    check deep_frozen(root) == false
    check deep_frozen(nested) == false

  test "freeze_value is idempotent":
    var root = new_array_value(new_map_value({"x".to_key(): "again".to_value()}.toTable()))
    clear_flags(root)
    let once = freeze_value(root)
    let root_flags = flags_of(root)
    let child_flags = flags_of(array_data(root)[0])
    let twice = freeze_value(root)

    check once == root
    check twice == root
    check flags_of(root) == root_flags
    check flags_of(array_data(root)[0]) == child_flags
    expect_frozen_flag(root)
    expect_frozen_flag(array_data(root)[0])

  test "cycles are handled without infinite recursion":
    var root = new_array_value()
    array_data(root).add(root)

    discard freeze_value(root)

    expect_frozen_flag(root)
    check array_data(root)[0] == root

  test "non heap immutables are accepted as no ops":
    let non_heap_values = @[
      7.to_value(),
      TRUE,
      NIL,
      'x'.to_value(),
      "sym".to_symbol_value(),
      new_bytes_value(@[1'u8, 2, 3]),
    ]

    for value in non_heap_values:
      let frozen = freeze_value(value)
      check frozen == value
      check deep_frozen(frozen)
