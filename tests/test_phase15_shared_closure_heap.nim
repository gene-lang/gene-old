import std/[atomics, os, sets, strutils, tables, unittest]

import ../src/gene/types except Exception
import ../src/gene/stdlib/freeze

type
  SharedSlot = object
    raw: Atomic[uint64]

  WorkerJob = object
    slot: ptr SharedSlot
    loops: int
    expected_checksum: int
    observed_checksum: int

proc ref_count_of(v: Value): int =
  let u = cast[uint64](v)
  let tag = u and 0xFFFF_0000_0000_0000'u64

  case tag
  of ARRAY_TAG:
    let arr = cast[ptr ArrayObj](u and PAYLOAD_MASK)
    if arr == nil: 0 else: arr.ref_count
  of MAP_TAG:
    let m = cast[ptr MapObj](u and PAYLOAD_MASK)
    if m == nil: 0 else: m.ref_count
  of GENE_TAG:
    let g = cast[ptr Gene](u and PAYLOAD_MASK)
    if g == nil: 0 else: g.ref_count
  of STRING_TAG:
    let s = cast[ptr String](u and PAYLOAD_MASK)
    if s == nil: 0 else: s.ref_count
  of REF_TAG:
    let r = cast[ptr Reference](u and PAYLOAD_MASK)
    if r == nil: 0 else: r.ref_count
  else:
    0

proc parse_env_int(name: string, default: int): int =
  let raw = getEnv(name)
  if raw.len == 0:
    return default
  try:
    parseInt(raw)
  except ValueError:
    default

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
    name: "phase15_shared_closure",
    ns: new_namespace("phase15"),
    scope_tracker: new_scope_tracker(),
    parent_scope: parent_scope,
    matcher: nil,
    body: @[]
  )
  result = r.to_ref_value()

proc read_payload(v: Value): int {.gcsafe.}

proc read_array_payload(v: Value): int {.gcsafe.} =
  var total = 0
  for item in array_data(v):
    total += read_payload(item)
  total

proc read_map_payload(v: Value): int {.gcsafe.} =
  var total = 0
  for _, value in map_data(v):
    total += read_payload(value)
  total

proc read_hash_map_payload(v: Value): int {.gcsafe.} =
  var total = 0
  for item in hash_map_items(v):
    total += read_payload(item)
  total

proc read_gene_payload(v: Value): int {.gcsafe.} =
  var total = 0
  if not v.gene.type.is_nil:
    total += read_payload(v.gene.type)
  for _, value in v.gene.props:
    total += read_payload(value)
  for child in v.gene.children:
    total += read_payload(child)
  total

proc read_closure_payload(v: Value): int {.gcsafe.} =
  doAssert v.kind == VkFunction
  doAssert deep_frozen(v)
  doAssert shared(v)

  var total = v.ref.fn.name.len
  var seen = initHashSet[uint64]()
  var scope = v.ref.fn.parent_scope

  while scope != nil:
    let id = cast[uint64](scope)
    if id in seen:
      break
    seen.incl(id)
    for item in scope.members:
      if item.kind == VkNamespace:
        continue
      total += read_payload(item)
    scope = scope.parent

  total

proc read_payload(v: Value): int {.gcsafe.} =
  case v.kind
  of VkNil, VkBool, VkFloat, VkChar, VkVoid:
    0
  of VkInt:
    v.to_int().int
  of VkSymbol:
    get_symbol((cast[uint64](v) and PAYLOAD_MASK).int).len
  of VkString:
    doAssert deep_frozen(v)
    if isManaged(v):
      doAssert shared(v)
    v.str.len
  of VkBytes:
    doAssert deep_frozen(v)
    if isManaged(v):
      doAssert shared(v)
    var total = 0
    for i in 0 ..< bytes_len(v):
      total += bytes_at(v, i).int
    total
  of VkArray:
    doAssert deep_frozen(v)
    if isManaged(v):
      doAssert shared(v)
    read_array_payload(v)
  of VkMap:
    doAssert deep_frozen(v)
    if isManaged(v):
      doAssert shared(v)
    read_map_payload(v)
  of VkHashMap:
    doAssert deep_frozen(v)
    if isManaged(v):
      doAssert shared(v)
    read_hash_map_payload(v)
  of VkGene:
    doAssert deep_frozen(v)
    if isManaged(v):
      doAssert shared(v)
    read_gene_payload(v)
  of VkFunction:
    read_closure_payload(v)
  else:
    0

proc build_shared_closure(depth: int): tuple[
  closure: Value,
  label: Value,
  numbers: Value,
  bytes_value: Value,
  payload_map: Value,
  meta: Value,
  config: Value,
  root: Value
] =
  var numbers = new_array_value()
  for i in 0 ..< depth:
    array_data(numbers).add((i + 1).to_value())

  let bytes_value = new_bytes_value(@[2'u8, 4, 6, 8, 10, 12])
  let payload_map = new_map_value({
    "numbers".to_key(): numbers,
    "bytes".to_key(): bytes_value,
    "label".to_key(): "closure-payload".to_value()
  }.toTable())
  let meta = new_hash_map_value(@[
    "status".to_value(), "ready".to_value(),
    "depth".to_value(), depth.to_value()
  ])
  let config = new_map_value({
    "offset".to_key(): depth.to_value(),
    "tag".to_key(): "phase15".to_value()
  }.toTable())

  var root = new_gene_value("SharedClosure".to_symbol_value())
  root.gene.props["payload".to_key()] = payload_map
  root.gene.props["meta".to_key()] = meta
  root.gene.children.add(new_array_value(depth.to_value(), "worker".to_value()))

  let outer_scope = new_named_scope([
    ("config", config),
  ])
  let label = "phase15-closure".to_value()
  let scope = new_named_scope([
    ("label", label),
    ("payload", root),
  ], outer_scope)

  result = (
    closure: new_test_closure(scope),
    label: label,
    numbers: numbers,
    bytes_value: bytes_value,
    payload_map: payload_map,
    meta: meta,
    config: config,
    root: root
  )

proc worker_read(job: ptr WorkerJob) {.thread, gcsafe.} =
  var total = 0
  for _ in 0 ..< job.loops:
    var raw = 0'u64
    while raw == 0'u64:
      raw = load(job.slot.raw)
    retainManaged(raw)
    let value = cast[Value](raw)
    total += read_payload(value)
    releaseManaged(raw)
  job.observed_checksum = total

suite "Phase 1.5 shared closure heap":
  test "frozen closures publish safely across threads with exact refcount restoration":
    let threads = parse_env_int("GENE_SHARED_HEAP_THREADS", 8)
    let loops = parse_env_int("GENE_SHARED_HEAP_LOOPS", 200)
    let depth = parse_env_int("GENE_SHARED_HEAP_DEPTH", 8)

    check threads > 0
    check loops > 0
    check depth > 0

    let built = build_shared_closure(depth)
    let shared_closure = freeze_value(built.closure)
    let expected_checksum = read_payload(shared_closure)

    let closure_refcount = ref_count_of(shared_closure)
    let label_refcount = ref_count_of(built.label)
    let numbers_refcount = ref_count_of(built.numbers)
    let bytes_refcount = ref_count_of(built.bytes_value)
    let payload_map_refcount = ref_count_of(built.payload_map)
    let meta_refcount = ref_count_of(built.meta)
    let config_refcount = ref_count_of(built.config)
    let root_refcount = ref_count_of(built.root)

    check deep_frozen(shared_closure)
    check shared(shared_closure)
    check closure_refcount >= 1
    check deep_frozen(built.root)
    check shared(built.root)
    check deep_frozen(built.payload_map)
    check shared(built.payload_map)
    check deep_frozen(built.numbers)
    check shared(built.numbers)

    var slot: SharedSlot
    slot.raw.store(shared_closure.raw)

    var jobs = newSeq[WorkerJob](threads)
    var workers = newSeq[system.Thread[ptr WorkerJob]](threads)

    for i in 0 ..< threads:
      jobs[i] = WorkerJob(
        slot: addr slot,
        loops: loops,
        expected_checksum: expected_checksum,
        observed_checksum: 0
      )
      createThread(workers[i], worker_read, addr jobs[i])

    for worker in workers.mitems:
      joinThread(worker)

    for job in jobs:
      check job.observed_checksum == job.expected_checksum * loops

    check ref_count_of(shared_closure) == closure_refcount
    check ref_count_of(built.label) == label_refcount
    check ref_count_of(built.numbers) == numbers_refcount
    check ref_count_of(built.bytes_value) == bytes_refcount
    check ref_count_of(built.payload_map) == payload_map_refcount
    check ref_count_of(built.meta) == meta_refcount
    check ref_count_of(built.config) == config_refcount
    check ref_count_of(built.root) == root_refcount
    check read_payload(shared_closure) == expected_checksum
