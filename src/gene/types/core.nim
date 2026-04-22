import hashes, tables, sets, re, bitops, unicode, strutils, strformat
import locks
import random
import times
import os
import asyncdispatch  # For async I/O support

import ./type_defs
import ../utils
export type_defs

#################### NaN Boxing implementation ####################
# We use the negative quiet NaN space (0xFFF0-0xFFFF prefix) for non-float values
# This allows all valid IEEE 754 floats to work correctly

const NAN_MASK* = 0xFFF0_0000_0000_0000u64

# Size limits for immediate integers (48-bit)
const SMALL_INT_MIN* = -(1'i64 shl 47)
const SMALL_INT_MAX* = (1'i64 shl 47) - 1

# Legacy constants for compatibility
const I64_MASK* = 0xC000_0000_0000_0000u64  # Will be removed

# Special values (using SPECIAL_TAG)
const NIL* = Value(raw: SPECIAL_TAG or 0)
const TRUE* = Value(raw: SPECIAL_TAG or 1)
const FALSE* = Value(raw: SPECIAL_TAG or 2)

const VOID* = Value(raw: SPECIAL_TAG or 3)
const PLACEHOLDER* = Value(raw: SPECIAL_TAG or 4)
# Used when a key does not exist in a map
const NOT_FOUND* = Value(raw: SPECIAL_TAG or 5)

# Special variable used by the parser
const PARSER_IGNORE* = Value(raw: SPECIAL_TAG or 6)

# Character encoding in special values (using SPECIAL_TAG prefix)
const CHAR_MASK = 0xFFF1_0000_0001_0000u64
const CHAR2_MASK = 0xFFF1_0000_0002_0000u64
const CHAR3_MASK = 0xFFF1_0000_0003_0000u64
const CHAR4_MASK = 0xFFF1_0000_0004_0000u64

# String constants

const EMPTY_STRING* = Value(raw: STRING_TAG)  # Empty string is a null pointer with STRING_TAG

const BIGGEST_INT =
  when sizeof(int) >= 8:
    int((2'i64 shl 61) - 1'i64)
  else:
    int.high

#################### Forward declarations #################
# Value basics
proc kind*(v: Value): ValueKind {.inline.}
proc `==`*(a, b: Value): bool {.gcsafe, noSideEffect.}
converter to_bool*(v: Value): bool {.inline.}
proc `$`*(self: Value): string {.gcsafe.}
proc `$`*(self: ptr Reference): string
proc `$`*(self: ptr Gene): string
template gene*(v: Value): ptr Gene =
  if (cast[uint64](v) and 0xFFFF_0000_0000_0000u64) == GENE_TAG:
    cast[ptr Gene](cast[uint64](v) and PAYLOAD_MASK)
  else:
    raise newException(ValueError, "Value is not a gene")

# String/symbol helpers
proc new_str*(s: string): ptr String
proc new_ref_string_value*(s: string): Value
proc new_str_value*(s: string): Value
proc str*(v: Value): string {.inline.}
converter to_value*(v: char): Value {.inline.}
converter to_value*(v: Rune): Value {.inline.}

# Scope/namespace helpers
proc update*(self: var Scope, scope: Scope) {.inline.}
proc `[]=`*(self: Namespace, key: Key, val: Value) {.inline.}

#################### Runtime globals #################

var VM* {.threadvar.}: ptr VirtualMachine   # The current virtual machine (per-thread)

# Application is shared across all threads (initialized once by main thread)
# After initialization, it's read-only so no locking needed
var App*: Value

# Threading support
const CHANNEL_LIMIT* = 1000  # Maximum messages in channel

# Absolute safety ceiling. Env var GENE_WORKERS is clamped to this.
const HARD_MAX_THREADS* = 4096

# Compile-time default thread cap, chosen per platform/arch.
# Overridable at runtime via GENE_WORKERS env var.
const DEFAULT_MAX_THREADS* =
  when defined(gene_wasm) or defined(emscripten) or defined(js):
    1
  elif sizeof(pointer) == 4:
    64
  elif defined(macosx):
    512
  elif defined(linux):
    1024
  elif defined(windows):
    512
  else:
    256

# Runtime-resolved thread cap. Set by init_thread_pool() from env var
# (falls back to DEFAULT_MAX_THREADS). Stays in sync with the allocated
# size of THREADS / THREAD_DATA.
var g_max_threads*: int = DEFAULT_MAX_THREADS

# Thread pool is shared across all threads (protected by thread_pool_lock in vm/thread.nim).
# Backed by manually-managed storage (not a seq) so {.gcsafe.} procs like
# thread_send_internal can access it without a GC-safety workaround.
# Pre-allocated to DEFAULT_MAX_THREADS at module load so THREADS[0] is valid
# before init_thread_pool() runs; resized on init via resize_thread_storage.
var THREADS*: ptr UncheckedArray[ThreadMetadata] =
  cast[ptr UncheckedArray[ThreadMetadata]](
    allocShared0(sizeof(ThreadMetadata) * DEFAULT_MAX_THREADS))

proc resolve_max_threads*(): int =
  ## Read GENE_WORKERS env var, clamp to [1, HARD_MAX_THREADS].
  ## Returns DEFAULT_MAX_THREADS if unset or invalid.
  ## On WASM targets, always returns 1 regardless of env.
  when defined(gene_wasm) or defined(emscripten) or defined(js):
    return 1
  else:
    result = DEFAULT_MAX_THREADS
    let env_val = getEnv("GENE_WORKERS")
    if env_val.len > 0:
      try:
        let n = parseInt(env_val)
        if n >= 1:
          result = min(n, HARD_MAX_THREADS)
      except ValueError:
        discard  # Keep default on parse error

var VmCreatedCallbacks*: seq[VmCallback] = @[]

# Callbacks invoked on each event loop iteration (used by HTTP handler queue, etc.)
type EventLoopCallback* = proc(vm: ptr VirtualMachine) {.gcsafe.}
var EventLoopCallbacks*: seq[EventLoopCallback] = @[]

# Flag to track if gene namespace has been initialized (thread-local for worker threads)
var gene_namespace_initialized* {.threadvar.}: bool

# Pre-interned keys for hot exec paths — computed once at init_app_and_vm(),
# safe to read from any thread (Key is a distinct int64, no GC involvement).
var KEY_SELF*:          Key   # "self"
var KEY_CALL*:          Key   # "call"
var KEY_EX*:            Key   # "ex"
var KEY_INIT*:          Key   # "init"
var KEY_INIT2*:         Key   # "__init__"

# Current thread ID (thread-local, 0 for main thread)
var current_thread_id* {.threadvar.}: int

randomize()

# Value conversion helpers
proc toValue*(raw: uint64): Value {.inline.} =
  ## Convert raw uint64 to Value (for interfacing with cast-heavy code)
  Value(raw: raw)

proc toRaw*(v: Value): uint64 {.inline.} =
  ## Extract raw uint64 from Value
  v.raw

include ./core/symbols
include ./core/value_ops
include ./core/constructors
include ./core/collections
include ./core/matchers
include ./core/functions
include ./core/enums
include ./core/futures
include ./core/native_helpers
include ./core/frames
