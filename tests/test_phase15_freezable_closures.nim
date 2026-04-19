import unittest, tables

import ../src/gene/types except Exception
import ../src/gene/stdlib/freeze

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

proc new_named_scope(captures: openArray[(string, Value)], parent: Scope = nil): Scope =
  var tracker =
    if parent == nil:
      new_scope_tracker()
    else:
      new_scope_tracker(parent.tracker)

  for (name, _) in captures:
    tracker.add(name.to_key())

  result = new_scope(tracker, parent)
  for (_, value) in captures:
    result.members.add(value)

proc new_test_closure(parent_scope: Scope): Value =
  let r = new_ref(VkFunction)
  r.fn = Function(
    name: "phase15_closure",
    ns: new_namespace("phase15"),
    scope_tracker: new_scope_tracker(),
    parent_scope: parent_scope,
    matcher: nil,
    body: @[]
  )
  result = r.to_ref_value()

suite "Phase 1.5 freezable closures":
  test "freeze_value accepts closures with freezable captured graphs":
    var leaf = new_array_value(2.to_value(), "leaf".to_value())
    var nested_map = new_map_value({"items".to_key(): leaf}.toTable())
    var hash_map = new_hash_map_value(@["payload".to_value(), nested_map])
    var bytes = new_bytes_value(@[1'u8, 2, 3, 4])
    var gene = new_gene_value("Widget".to_symbol_value())
    gene.gene.props["payload".to_key()] = hash_map
    gene.gene.children.add(bytes)

    let scope = new_named_scope([
      ("label", "captured".to_value()),
      ("payload", gene),
    ])
    let closure = new_test_closure(scope)

    clear_flags(closure)
    clear_flags(scope.members[0])
    clear_flags(gene)
    clear_flags(hash_map)
    clear_flags(nested_map)
    clear_flags(leaf)
    clear_flags(bytes)

    let frozen = freeze_value(closure)

    check frozen == closure
    expect_frozen_flag(closure)
    expect_frozen_flag(scope.members[0])
    expect_frozen_flag(gene)
    expect_frozen_flag(hash_map)
    expect_frozen_flag(nested_map)
    expect_frozen_flag(leaf)
    expect_frozen_flag(bytes)

  test "freeze_value reports deterministic closure capture paths":
    let scope = new_named_scope([
      ("blocked", new_ref(VkNativeFn).to_ref_value()),
    ])
    let closure = new_test_closure(scope)

    var caught = false
    try:
      discard freeze_value(closure)
      fail()
    except FreezeScopeError as err:
      caught = true
      check err.offending_kind == VkNativeFn
      check err.path == "/<closure>/<scope:0>/<capture:blocked>"
    check caught

  test "validation failures leave closures and captured graphs untagged":
    var nested = new_map_value({"ok".to_key(): new_array_value(1.to_value())}.toTable())
    let parent = new_named_scope([
      ("nested", nested),
    ])
    let scope = new_named_scope([
      ("blocked", new_ref(VkClass).to_ref_value()),
    ], parent)
    let closure = new_test_closure(scope)

    clear_flags(closure)
    clear_flags(nested)
    clear_flags(map_data(nested)["ok".to_key()])

    var caught = false
    try:
      discard freeze_value(closure)
      fail()
    except FreezeScopeError as err:
      caught = true
      check err.offending_kind == VkClass
      check err.path == "/<closure>/<scope:0>/<capture:blocked>"
    check caught
    check flags_of(closure) == 0'u8
    check flags_of(nested) == 0'u8
    check flags_of(map_data(nested)["ok".to_key()]) == 0'u8
    check deep_frozen(closure) == false
    check deep_frozen(nested) == false
    check deep_frozen(map_data(nested)["ok".to_key()]) == false

  test "freeze_value is idempotent across closure cycles":
    var scope = new_named_scope([])
    let closure = new_test_closure(scope)
    var cycle = new_array_value()
    array_data(cycle).add(cycle)
    scope.tracker.add("self".to_key())
    scope.members.add(closure)
    scope.tracker.add("cycle".to_key())
    scope.members.add(cycle)

    clear_flags(closure)
    clear_flags(cycle)

    let once = freeze_value(closure)
    let closure_flags = flags_of(closure)
    let cycle_flags = flags_of(cycle)
    let twice = freeze_value(closure)

    check once == closure
    check twice == closure
    check scope.members[0] == closure
    check flags_of(closure) == closure_flags
    check flags_of(cycle) == cycle_flags
    expect_frozen_flag(closure)
    expect_frozen_flag(cycle)
