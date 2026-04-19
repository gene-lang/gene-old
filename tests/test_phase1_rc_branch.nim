{.define: phase1_rc_branch_probe.}

import std/[strformat, times, unittest]

import gene/types except Exception

type RcStressJob = object
  raw: uint64
  loops: int

proc ref_count_of(v: Value): int =
  let u = cast[uint64](v)
  let tag = u and 0xFFFF_0000_0000_0000'u64

  case tag:
    of ARRAY_TAG:
      let arr = cast[ptr ArrayObj](u and PAYLOAD_MASK)
      if arr == nil: 0 else: arr.ref_count
    of MAP_TAG:
      let m = cast[ptr MapObj](u and PAYLOAD_MASK)
      if m == nil: 0 else: m.ref_count
    of INSTANCE_TAG:
      let inst = cast[ptr InstanceObj](u and PAYLOAD_MASK)
      if inst == nil: 0 else: inst.ref_count
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

when declared(resetRcBranchProbe):
  proc expect_probe_counts(plain_inc, atomic_inc, plain_dec, atomic_dec: int) =
    check rcBranchProbeCount(RcPlainInc) == plain_inc
    check rcBranchProbeCount(RcAtomicInc) == atomic_inc
    check rcBranchProbeCount(RcPlainDec) == plain_dec
    check rcBranchProbeCount(RcAtomicDec) == atomic_dec

  proc expect_shared_branch(value: var Value) =
    resetRcBranchProbe()

    let baseline = ref_count_of(value)
    check baseline >= 1
    check shared(value) == false

    retainManaged(value.raw)
    releaseManaged(value.raw)

    check ref_count_of(value) == baseline
    expect_probe_counts(1, 0, 1, 0)

    setShared(value)
    check shared(value)

    resetRcBranchProbe()
    retainManaged(value.raw)
    releaseManaged(value.raw)

    check ref_count_of(value) == baseline
    expect_probe_counts(0, 1, 0, 1)

when declared(setShared) and declared(setRcBranchProbeEnabled):
  proc rc_stress_worker(job: ptr RcStressJob) {.thread.} =
    for _ in 0 ..< job.loops:
      retainManaged(job.raw)
      releaseManaged(job.raw)

  proc run_shared_stress(value: var Value, threads = 8, loops = 100_000) =
    setShared(value)
    setRcBranchProbeEnabled(false)

    let baseline = ref_count_of(value)
    var jobs = newSeq[RcStressJob](threads)
    var worker_threads = newSeq[system.Thread[ptr RcStressJob]](threads)

    for i in 0 ..< threads:
      jobs[i] = RcStressJob(raw: value.raw, loops: loops)
      createThread(worker_threads[i], rc_stress_worker, addr jobs[i])

    for worker in worker_threads.mitems:
      joinThread(worker)

    setRcBranchProbeEnabled(true)
    check ref_count_of(value) == baseline

proc benchmark_owned_array(iterations = 5_000_000): float =
  var value = new_array_value()
  let start = cpuTime()
  for _ in 0 ..< iterations:
    retainManaged(value.raw)
    releaseManaged(value.raw)
  let elapsed = cpuTime() - start
  let ns_per_pair = (elapsed * 1_000_000_000.0) / iterations.float
  echo &"BENCH owned_array iterations={iterations} total_seconds={elapsed:.6f} ns_per_pair={ns_per_pair:.2f}"
  ns_per_pair

suite "Phase 1 RC branch":
  when declared(resetRcBranchProbe):
    test "managed arms branch to plain then atomic based on shared bit":
      var array_value = new_array_value()
      expect_shared_branch(array_value)

      var map_value = new_map_value()
      expect_shared_branch(map_value)

      var gene_value = new_gene_value()
      expect_shared_branch(gene_value)

      var ref_value = new_bytes_value(@[1'u8, 2, 3, 4, 5, 6, 7, 8])
      expect_shared_branch(ref_value)

      var string_value = "phase1-rc-branch".to_value()
      expect_shared_branch(string_value)
      
      var instance_value = new_instance_value(nil)
      expect_shared_branch(instance_value)

  when declared(setShared) and declared(setRcBranchProbeEnabled):
    test "shared values survive concurrent retain/release loops with exact refcount":
      var array_value = new_array_value()
      run_shared_stress(array_value)

      var ref_value = new_bytes_value(@[11'u8, 12, 13, 14, 15, 16, 17, 18])
      run_shared_stress(ref_value)

      var instance_value = new_instance_value(nil)
      run_shared_stress(instance_value)

discard benchmark_owned_array()
