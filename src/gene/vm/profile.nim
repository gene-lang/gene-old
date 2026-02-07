## VM profiling output: function and instruction profile reports.

import strutils, strformat, algorithm, tables

import ../types

proc print_profile*(self: ptr VirtualMachine) =
  if not self.profiling or self.profile_data.len == 0:
    echo "No profiling data available"
    return

  echo "\n=== Function Profile Report ==="
  echo "Function                       Calls      Total(ms)       Avg(μs)     Min(μs)     Max(μs)"
  echo repeat('-', 94)

  # Sort by total time descending
  var profiles: seq[FunctionProfile] = @[]
  for name, profile in self.profile_data:
    profiles.add(profile)

  profiles.sort do (a, b: FunctionProfile) -> int:
    if a.total_time > b.total_time: -1
    elif a.total_time < b.total_time: 1
    else: 0

  for profile in profiles:
    let total_ms = profile.total_time * 1000.0
    let avg_us = if profile.call_count > 0: (profile.total_time * 1_000_000.0) / profile.call_count.float else: 0.0
    let min_us = profile.min_time * 1_000_000.0
    let max_us = profile.max_time * 1_000_000.0

    # Use manual formatting for now
    var name_str = profile.name
    if name_str.len > 30:
      name_str = name_str[0..26] & "..."
    while name_str.len < 30:
      name_str = name_str & " "

    echo fmt"{name_str} {profile.call_count:10} {total_ms:12.3f} {avg_us:12.3f} {min_us:10.3f} {max_us:10.3f}"

  echo "\nTotal functions profiled: ", self.profile_data.len

proc print_instruction_profile*(self: ptr VirtualMachine) =
  if not self.instruction_profiling:
    echo "No instruction profiling data available"
    return

  echo "\n=== Instruction Profile Report ==="
  echo "Instruction              Count        Total(ms)     Avg(ns)    Min(ns)    Max(ns)     %Time"
  echo repeat('-', 94)

  # Calculate total time
  var total_time = 0.0
  for kind in InstructionKind:
    if self.instruction_profile[kind].count > 0:
      total_time += self.instruction_profile[kind].total_time

  # Collect and sort instructions by total time
  type InstructionStat = tuple[kind: InstructionKind, profile: InstructionProfile]
  var stats: seq[InstructionStat] = @[]
  for kind in InstructionKind:
    if self.instruction_profile[kind].count > 0:
      stats.add((kind, self.instruction_profile[kind]))

  stats.sort do (a, b: InstructionStat) -> int:
    if a.profile.total_time > b.profile.total_time: -1
    elif a.profile.total_time < b.profile.total_time: 1
    else: 0

  # Print top instructions
  for stat in stats:
    let kind = stat.kind
    let profile = stat.profile
    let total_ms = profile.total_time * 1000.0
    let avg_ns = if profile.count > 0: (profile.total_time * 1_000_000_000.0) / profile.count.float else: 0.0
    let min_ns = profile.min_time * 1_000_000_000.0
    let max_ns = profile.max_time * 1_000_000_000.0
    let percent = if total_time > 0: (profile.total_time / total_time) * 100.0 else: 0.0

    # Format instruction name
    var name_str = $kind
    if name_str.startswith("Ik"):
      name_str = name_str[2..^1]  # Remove "Ik" prefix
    if name_str.len > 24:
      name_str = name_str[0..20] & "..."
    while name_str.len < 24:
      name_str = name_str & " "

    echo fmt"{name_str} {profile.count:12} {total_ms:12.3f} {avg_ns:10.1f} {min_ns:9.1f} {max_ns:9.1f} {percent:8.2f}%"

  echo fmt"Total time: {total_time * 1000.0:.3f} ms"
  echo "Instructions profiled: ", stats.len
