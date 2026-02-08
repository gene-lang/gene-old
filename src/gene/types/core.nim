import math, hashes, tables, sets, re, bitops, unicode, strutils, strformat
import locks
import random
import times
import os
import asyncdispatch  # For async I/O support

import ./type_defs
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

const BIGGEST_INT = 2^61 - 1

#################### Forward declarations #################
# Value basics
proc kind*(v: Value): ValueKind {.inline.}
proc `==`*(a, b: Value): bool {.no_side_effect.}
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
const MAX_THREADS* = 64      # Maximum number of threads in pool

# Thread pool is shared across all threads (protected by thread_pool_lock in vm/thread.nim)
var THREADS*: array[MAX_THREADS, ThreadMetadata]

var VmCreatedCallbacks*: seq[VmCallback] = @[]

# Callbacks invoked on each event loop iteration (used by HTTP handler queue, etc.)
type EventLoopCallback* = proc(vm: ptr VirtualMachine) {.gcsafe.}
var EventLoopCallbacks*: seq[EventLoopCallback] = @[]

# Flag to track if gene namespace has been initialized (thread-local for worker threads)
var gene_namespace_initialized* {.threadvar.}: bool

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
