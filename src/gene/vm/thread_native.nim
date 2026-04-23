import locks, random, options, os
import ../types

# Simple channel implementation for MVP
type
  Channel*[T] = ptr ChannelObj[T]

  ChannelObj*[T] = object
    lock: Lock
    cond: Cond
    data: seq[T]
    capacity: int
    closed: bool

proc open*[T](ch: var Channel[T], capacity: int) =
  if ch != nil:
    return  # Already opened
  ch = cast[Channel[T]](alloc0(sizeof(ChannelObj[T])))
  initLock(ch.lock)
  initCond(ch.cond)
  ch.data = newSeq[T](0)
  ch.capacity = capacity
  ch.closed = false

proc close*[T](ch: Channel[T]) =
  if ch == nil:
    return
  acquire(ch.lock)
  ch.closed = true
  broadcast(ch.cond)
  release(ch.lock)

proc send*[T](ch: Channel[T], item: T) =
  acquire(ch.lock)

  # Wait if full
  while ch.data.len >= ch.capacity and not ch.closed:
    wait(ch.cond, ch.lock)

  if not ch.closed:
    ch.data.add(item)
    signal(ch.cond)

  release(ch.lock)

proc recv*[T](ch: Channel[T]): T =
  acquire(ch.lock)

  # Wait for data
  while ch.data.len == 0 and not ch.closed:
    wait(ch.cond, ch.lock)

  if ch.data.len > 0:
    result = ch.data[0]
    ch.data.delete(0)
    signal(ch.cond)

  release(ch.lock)

proc try_recv*[T](ch: Channel[T]): Option[T] =
  ## Non-blocking receive - returns Some(value) if data available, None otherwise
  acquire(ch.lock)

  if ch.data.len > 0:
    result = some(ch.data[0])
    ch.data.delete(0)
    signal(ch.cond)
  else:
    result = none(T)

  release(ch.lock)

# Thread-local channel and threading data
type
  ThreadChannel* = Channel[ThreadMessage]  # Store refs directly, not pointers

  ThreadDataObj* = object
    thread*: system.Thread[int]
    channel*: ThreadChannel

var THREAD_DATA*: ptr UncheckedArray[ThreadDataObj] =
  cast[ptr UncheckedArray[ThreadDataObj]](
    allocShared0(sizeof(ThreadDataObj) * DEFAULT_MAX_THREADS))
  ## Shared across threads (channels are thread-safe). Resized to g_max_threads in init_thread_pool().
  ## Manually-managed storage (not a seq) so gcsafe procs can access it.

proc resize_thread_storage(new_cap: int) =
  ## Reallocate THREADS and THREAD_DATA to new_cap entries.
  ## Must be called before any worker threads exist for the new slots.
  if new_cap == g_max_threads and THREADS != nil and THREAD_DATA != nil:
    return
  if THREADS != nil:
    deallocShared(THREADS)
  if THREAD_DATA != nil:
    deallocShared(THREAD_DATA)
  THREADS = cast[ptr UncheckedArray[ThreadMetadata]](
    allocShared0(sizeof(ThreadMetadata) * new_cap))
  THREAD_DATA = cast[ptr UncheckedArray[ThreadDataObj]](
    allocShared0(sizeof(ThreadDataObj) * new_cap))
  g_max_threads = new_cap
var THREAD_CLASS_VALUE*: Value  # Cached thread class value for quick access across threads
var THREAD_MESSAGE_CLASS_VALUE*: Value

# Thread pool management
var thread_pool_lock: Lock
var next_message_id* {.threadvar.}: int
var message_id_lock: Lock
var next_shared_message_id = 0

initLock(message_id_lock)

proc next_thread_message_id*(): int =
  acquire(message_id_lock)
  result = next_shared_message_id
  next_shared_message_id.inc()
  release(message_id_lock)

proc init_thread_pool*() =
  ## Initialize the thread pool (call once from main thread).
  ## Reads GENE_WORKERS env var to determine pool size.
  randomize()  # Initialize random number generator
  initLock(thread_pool_lock)
  next_message_id = 0
  acquire(message_id_lock)
  next_shared_message_id = 0
  release(message_id_lock)

  # Terminate and clean up any existing worker threads/channels.
  # Iterate over current slot count (may differ from target on re-init).
  let current_cap = g_max_threads
  for i in 1..<current_cap:
    if THREAD_DATA[i].channel != nil:
      # Ask the worker to exit and wait for it to finish
      var term: ThreadMessage
      new(term)
      term.id = next_thread_message_id()
      term.msg_type = MtTerminate
      term.payload = NIL
      term.payload_bytes = ThreadPayload(bytes: @[])
      term.from_thread_id = 0
      term.from_thread_secret = THREADS[0].secret
      THREAD_DATA[i].channel.send(term)
      # Join the thread if it was ever started
      if THREADS[i].in_use or THREADS[i].state != TsFree:
        joinThread(THREAD_DATA[i].thread)
      close(THREAD_DATA[i].channel)
      THREAD_DATA[i].channel = nil

  # Reset main thread channel if it was previously opened
  if THREAD_DATA[0].channel != nil:
    close(THREAD_DATA[0].channel)
    THREAD_DATA[0].channel = nil

  # Resolve pool size from env var and reallocate backing storage.
  # Does nothing if the requested cap equals the current cap.
  resize_thread_storage(resolve_max_threads())

  # Initialize thread 0 as main thread
  THREADS[0].id = 0
  THREADS[0].secret = rand(int.high)
  THREADS[0].state = TsBusy
  THREADS[0].in_use = true
  THREADS[0].parent_id = 0
  THREADS[0].parent_secret = THREADS[0].secret

  THREAD_DATA[0].channel.open(CHANNEL_LIMIT)

  # Initialize other thread slots as free
  for i in 1..<g_max_threads:
    THREADS[i].id = i
    THREADS[i].state = TsFree
    THREADS[i].in_use = false
    THREADS[i].parent_id = 0
    THREADS[i].parent_secret = 0
    THREADS[i].secret = 0

proc get_free_thread*(): int =
  ## Find and allocate a free thread slot
  ## Returns -1 if no threads available
  acquire(thread_pool_lock)
  defer: release(thread_pool_lock)

  for i in 1..<g_max_threads:
    if not THREADS[i].in_use and THREADS[i].state == TsFree:
      THREADS[i].in_use = true
      THREADS[i].state = TsBusy
      THREADS[i].secret = rand(int.high)
      return i
  return -1

proc init_thread*(thread_id: int, parent_id: int = 0) =
  ## Initialize worker metadata
  THREADS[thread_id].id = thread_id
  THREADS[thread_id].parent_id = parent_id
  THREADS[thread_id].parent_secret = THREADS[parent_id].secret
  THREADS[thread_id].state = TsBusy

  # Open channel for this thread
  THREAD_DATA[thread_id].channel.open(CHANNEL_LIMIT)

proc cleanup_thread*(thread_id: int) =
  ## Clean up thread and mark as free
  acquire(thread_pool_lock)
  defer: release(thread_pool_lock)

  THREADS[thread_id].state = TsFree
  THREADS[thread_id].in_use = false
  THREADS[thread_id].secret = rand(int.high)  # Rotate secret

  # Close channel
  THREAD_DATA[thread_id].channel.close()

# VM state reset
proc reset_vm_state*() =
  ## Reset VM state for thread reuse
  VM.pc = 0
  VM.cu = nil
  VM.trace = false

  # Return all frames to pool
  var current_frame = VM.frame
  while current_frame != nil:
    let caller = current_frame.caller_frame
    current_frame.free()
    current_frame = caller
  VM.frame = nil

  # Clear exception handlers
  VM.exception_handlers.setLen(0)
  VM.current_exception = NIL
  VM.repl_exception = NIL
  VM.repl_on_error = false
  VM.repl_active = false
  VM.repl_skip_on_throw = false
  VM.repl_ran = false
  VM.repl_resume_value = NIL

  # Clear generator state
  VM.current_generator = nil

# Thread pool initialization must be called from main thread
# This will be called from vm.nim

# Thread class initialization
proc init_thread_class*() =
  ## Phase 4 removes the public thread-first surface.
  ## The internal worker substrate still exists for actor scheduling, but
  ## Thread / ThreadMessage are no longer published as public classes.
  THREAD_CLASS_VALUE = NIL
  THREAD_MESSAGE_CLASS_VALUE = NIL
