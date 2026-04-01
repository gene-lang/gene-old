## Symbol table: to_symbol_value, to_key, get_symbol.
## Included from core.nim — shares its scope.

#################### Symbol #####################

var SYMBOLS*: ManagedSymbols
var SYMBOLS_SHARED*: ptr ManagedSymbols = nil
var SYMBOLS_LOCK: Lock

initLock(SYMBOLS_LOCK)

proc active_symbols_ptr(): ptr ManagedSymbols {.inline.} =
  if SYMBOLS_SHARED != nil:
    SYMBOLS_SHARED
  else:
    addr SYMBOLS

proc get_symbol*(i: int): string {.inline.} =
  {.cast(gcsafe).}:
    acquire(SYMBOLS_LOCK)
    try:
      result = active_symbols_ptr()[].store[i]
    finally:
      release(SYMBOLS_LOCK)

proc get_symbol_gcsafe*(i: int): string {.inline, gcsafe.} =
  {.cast(gcsafe).}:
    acquire(SYMBOLS_LOCK)
    try:
      result = active_symbols_ptr()[].store[i]
    finally:
      release(SYMBOLS_LOCK)

proc to_symbol_value*(s: string): Value =
  {.cast(gcsafe).}:
    acquire(SYMBOLS_LOCK)
    try:
      let symbols = active_symbols_ptr()
      let found = symbols[].map.get_or_default(s, -1)
      if found != -1:
        let i = found.uint64
        result = cast[Value](SYMBOL_TAG or i)
      else:
        let new_id = symbols[].store.len.uint64
        # Ensure symbol ID fits in 48 bits
        assert new_id <= PAYLOAD_MASK, "Too many symbols for NaN boxing"
        result = cast[Value](SYMBOL_TAG or new_id)
        symbols[].map[s] = symbols[].store.len
        symbols[].store.add(s)
    finally:
      release(SYMBOLS_LOCK)

proc to_key*(s: string): Key {.inline.} =
  cast[Key](to_symbol_value(s))

# Extract symbol index from Key for symbol table lookup
# Key is a symbol value cast to int64, so we need to extract the symbol index
proc symbol_index*(k: Key): int {.inline.} =
  int(cast[uint64](k) and PAYLOAD_MASK)

#################### String intern table ####################

var STRING_INTERN: Table[string, ptr String]
var STRING_INTERN_LOCK: Lock

initLock(STRING_INTERN_LOCK)

const MAX_INTERN_STRING_LEN* = 64   ## Strings longer than this are not interned
const MAX_INTERN_TABLE_SIZE* = 8192 ## Maximum number of interned strings

proc intern_str_value*(s: string): Value {.gcsafe.} =
  ## Return an interned Value for short strings, allocating a fresh one for long strings.
  ## Interned strings share a single heap object; a permanent table reference keeps them alive.
  if s.len == 0:
    return EMPTY_STRING
  if s.len > MAX_INTERN_STRING_LEN:
    let str_ptr = cast[ptr String](alloc0(sizeof(String)))
    str_ptr.ref_count = 1
    str_ptr.str = s
    let ptr_addr = cast[uint64](str_ptr)
    assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "String pointer too large for NaN boxing"
    return cast[Value](STRING_TAG or ptr_addr)
  {.cast(gcsafe).}:
    acquire(STRING_INTERN_LOCK)
    try:
      let existing = STRING_INTERN.getOrDefault(s, nil)
      if existing != nil:
        existing.ref_count.inc()  # caller's reference
        return cast[Value](STRING_TAG or cast[uint64](existing))
      if STRING_INTERN.len >= MAX_INTERN_TABLE_SIZE:
        # Table full — uninterned fallback
        let str_ptr = cast[ptr String](alloc0(sizeof(String)))
        str_ptr.ref_count = 1
        str_ptr.str = s
        let ptr_addr = cast[uint64](str_ptr)
        assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "String pointer too large for NaN boxing"
        return cast[Value](STRING_TAG or ptr_addr)
      let str_ptr = cast[ptr String](alloc0(sizeof(String)))
      str_ptr.ref_count = 1    # table's permanent reference
      str_ptr.str = s
      let ptr_addr = cast[uint64](str_ptr)
      assert (ptr_addr and 0xFFFF_0000_0000_0000u64) == 0, "String pointer too large for NaN boxing"
      STRING_INTERN[s] = str_ptr
      str_ptr.ref_count.inc()  # caller's reference → count = 2
      return cast[Value](STRING_TAG or ptr_addr)
    finally:
      release(STRING_INTERN_LOCK)
