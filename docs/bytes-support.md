# Binary Data and Bytes Literal Support

## Motivation

Gene has `VkBytes` (heap-allocated `seq[uint8]`) and three parser stubs for binary
literals (`parse_bin`, `parse_hex`, `parse_base64` in `parser.nim:1345-1457`), but
all hit `todo()`. The only way to get bytes today is via string methods (`.bytes`,
`.byteslice`). This document specifies the literal syntax, a NaN-boxed immediate
representation for small byte values, and the Bytes class.

## Literal Syntax

### Syntax

| Prefix | Produces | Format |
|--------|----------|--------|
| `0!` | Bytes | Binary digits |
| `0#` | Bytes | Hex digits |
| `0*` | Bytes | Base64 encoded |
| `0x` | **Integer** | Hex integer (unchanged, standard) |

**`0x` vs `0#`:** `0xff` is integer 255. `0#ff` is a 1-byte value containing that
byte. The deliberate split: `0x` for numeric values (standard convention), `0#` for
byte data, avoids ambiguity.

Gene does not currently support `0x` hex integers — this work adds it alongside the
byte literal prefixes. In the parser, `0x` routes to integer parsing (parse hex
digits, produce VkInt); `0#` routes to byte parsing (parse hex digits, produce
VkBytes).

### Binary Literals (`0!`)

```gene
0!11110000                    # 1 byte: 0xF0
0!1111~0000                   # Same with ~ separator for readability
0!00000001~10000000           # 2 bytes: 0x01 0x80
0!11111111~11111111~11111111~11111111  # 4 bytes
```

- Digits: `0`, `1`
- `~` is a visual separator; `~` and any following whitespace are ignored, allowing
  multi-line literals: `0!1111~\n  0000` is valid
- Bits are grouped into bytes (MSB first)
- Partial final byte: left-padded with zeros (e.g., `0!111` = `0!00000111` → `0x07`)

### Hex Bytes Literals (`0#`)

```gene
0#a0                          # 1 byte: 160
0#A0FF                        # 2 bytes
0#a0~ff~00~11                 # 4 bytes with separators
0#0102030405060708            # 8 bytes (heap-allocated)
```

- Digits: `0-9`, `a-f`, `A-F` (case-insensitive)
- `~` is a visual separator; `~` and any following whitespace are ignored
- Odd number of hex digits: left-padded with zero (e.g., `0#f` → `0#0f`)

### Base64 Literals (`0*`)

```gene
0*AQID                        # 3 bytes: [1, 2, 3]
0*AQID~BAUG                   # 6 bytes with separator
0*SGVsbG8=                    # "Hello" as bytes
```

- Characters: `A-Z`, `a-z`, `0-9`, `+`, `/`, `=`
- `~` is a visual separator; `~` and any following whitespace are ignored
- Standard base64 decoding (RFC 4648)

## NaN-Boxed Immediate Bytes

Small byte values (1-6 bytes) are stored as NaN-boxed immediates — no heap
allocation, no ref-counting. This benefits common use cases: single bytes, uint16
values, IPv4 addresses, MAC addresses, colors, short protocol fields.

### Tag Allocation

Two new tags in the non-managed NaN space:

```
0xFFF5: BYTES_TAG   — 1-5 bytes (size + data in payload)
0xFFF6: BYTES6_TAG  — exactly 6 bytes (full 48-bit payload)
```

Leaves `0xFFF7` free for future use.

### Bit Layout

**BYTES_TAG (0xFFF5) — 1 to 5 bytes:**

```
63        48 47 46 45 44 43          40 39              0
┌──────────┬────────┬────────────────┬──────────────────┐
│  0xFFF5  │  size  │   (unused)     │      data        │
└──────────┴────────┴────────────────┴──────────────────┘

size (bits 47-45): byte count (001=1, 010=2, 011=3, 100=4, 101=5)
data (bits 39-0):  up to 5 bytes, big-endian, right-aligned
```

Unused upper data bits are zero. Size 0 and 6-7 are invalid for this tag.

**BYTES6_TAG (0xFFF6) — exactly 6 bytes:**

```
63        48 47                                       0
┌──────────┬──────────────────────────────────────────┐
│  0xFFF6  │              6 bytes of data             │
└──────────┴──────────────────────────────────────────┘
```

Full 48-bit payload used for data. No size encoding needed — it's always 6 bytes.

### Size Routing

| Byte count | Storage | Tag |
|------------|---------|-----|
| 1-5 | Immediate | BYTES_TAG (size in bits 47-45) |
| 6 | Immediate | BYTES6_TAG |
| 7+ | Heap | REF_TAG → VkBytes |

### Value Kind Detection

The `kind` proc needs to recognize the new tags:

```nim
if tag == BYTES_TAG or tag == BYTES6_TAG:
  return VkBytes  # Unify under VkBytes for user code
```

User code sees `VkBytes` for all byte values regardless of storage. The immediate
vs heap distinction is transparent.

## Type System Changes

### Simplification

The existing `VkBin`, `VkBin64`, `VkByte` value kinds (defined in `type_defs.nim:154-156`)
with their `bit_size` fields are **removed**. They were never wired up and the bit-size
tracking adds complexity without clear benefit. All binary data is represented as:

- **Immediate bytes** (1-6 bytes) — NaN-boxed, no heap allocation
- **VkBytes** (any size) — heap-allocated `seq[uint8]`

Both present as `VkBytes` to user code.

### Constants

New constants in `memory.nim`:

```nim
const BYTES_TAG*  = 0xFFF5_0000_0000_0000u64
const BYTES6_TAG* = 0xFFF6_0000_0000_0000u64

# Size encoding in BYTES_TAG payload (bits 47-45)
const BYTES_SIZE_SHIFT* = 45
const BYTES_SIZE_MASK*  = 0x0000_E000_0000_0000u64  # 3 bits at 47-45
const BYTES_DATA_MASK*  = 0x0000_00FF_FFFF_FFFFu64  # 40 bits at 39-0
```

### Constructor Functions

```nim
proc new_bytes_value*(data: openArray[uint8]): Value =
  let n = data.len
  if n >= 1 and n <= 5:
    # Pack size in bits 47-45, data big-endian right-aligned in bits 39-0
    var payload = n.uint64 shl BYTES_SIZE_SHIFT
    for i in 0 ..< n:
      payload = payload or (data[i].uint64 shl ((n - 1 - i) * 8))
    Value(raw: BYTES_TAG or payload)
  elif n == 6:
    var payload: uint64 = 0
    for i in 0 ..< 6:
      payload = payload or (data[i].uint64 shl ((5 - i) * 8))
    Value(raw: BYTES6_TAG or payload)
  else:
    # Heap-allocate for 7+ bytes
    let r = new_ref(VkBytes)
    r.bytes_data = @data
    r.to_ref_value()
```

### Byte Extraction

```nim
proc bytes_len*(v: Value): int =
  let tag = v.raw and 0xFFFF_0000_0000_0000u64
  if tag == BYTES6_TAG: return 6
  if tag == BYTES_TAG:
    return int((v.raw and BYTES_SIZE_MASK) shr BYTES_SIZE_SHIFT)
  # Heap VkBytes
  return v.ref.bytes_data.len

proc bytes_at*(v: Value, i: int): uint8 =
  let tag = v.raw and 0xFFFF_0000_0000_0000u64
  let n = bytes_len(v)
  if i < 0 or i >= n:
    raise new_exception(types.Exception, "Bytes index out of bounds: " & $i)
  if tag == BYTES6_TAG:
    return uint8((v.raw shr ((5 - i) * 8)) and 0xFF)
  elif tag == BYTES_TAG:
    return uint8((v.raw shr ((n - 1 - i) * 8)) and 0xFF)
  else:
    return v.ref.bytes_data[i]
```

## Parser Changes

### Dispatch (`read_number`, parser.nim:1511-1522)

Change the prefix routing:

```nim
of '!':
  self.bufpos += 2
  return self.parse_bin()      # 0! — binary bytes
of '#':
  self.bufpos += 2
  return self.parse_hex()      # 0# — hex bytes
of '*':
  self.bufpos += 2
  return self.parse_base64()   # 0* — base64 bytes
of 'x', 'X':
  self.bufpos += 2
  return self.parse_hex_int()  # 0x — hex integer (NEW)
```

### Hex Integer Parsing (`parse_hex_int`)

New proc that reads hex digits and produces a VkInt:

```nim
proc parse_hex_int(self: var Parser): Value =
  var pos = self.bufpos
  var n: int64 = 0
  while true:
    let ch = self.buf[pos]
    if ch in '0'..'9':
      n = n shl 4 or (ord(ch) - ord('0')).int64
    elif ch in 'a'..'f':
      n = n shl 4 or (ord(ch) - ord('a') + 10).int64
    elif ch in 'A'..'F':
      n = n shl 4 or (ord(ch) - ord('A') + 10).int64
    elif ch == '_':
      inc(pos); continue  # _ separator for readability (0xFF_FF)
    else:
      break
    inc(pos)
  if pos == self.bufpos:
    raise new_exception(ParseError, "Expected hex digits after 0x")
  self.bufpos = pos
  n.to_value()
```

Supports `_` as digit separator (`0xFF_FF_FF` → 16777215). Overflow beyond int64
raises via `to_value()` (same behavior as decimal integer overflow).

### Wire `todo()` Stubs

All three parse procs (`parse_bin`, `parse_hex`, `parse_base64`) already have the
parsing logic — they correctly build `bytes: seq[uint8]`. Replace the `todo()` calls
with:

```nim
return new_bytes_value(bytes)
```

The `new_bytes_value` constructor handles size routing (immediate vs heap) transparently.

### Remove VkByte/VkBin Branching

The old stubs had separate paths for single-byte vs multi-byte (`VkByte` vs `VkBin`).
This distinction is eliminated — all sizes go through `new_bytes_value`.

### Parser Bug Fixes During Implementation

- `parse_hex` line 1409: error message says `"parse_bin: input length is zero."` —
  copy-paste bug, should say `"parse_hex"`.
- `parse_base64`: no validation on input characters. Invalid base64 input (e.g.,
  `0*!!invalid`) could crash or produce garbage. Add a `ParseError` if `decode()`
  fails.
- `parse_bin` partial byte handling (line 1363-1365): currently right-packs bits.
  For left-padding behavior (`0!111` → `0x07`), the partial byte needs to be
  right-shifted by `(8 - (size mod 8))` bits before adding to the byte sequence.

### Equality Across Storage

An immediate 2-byte `0#abcd` must equal a heap-allocated `0#abcd` (e.g., created by
slicing a larger value). Both are `VkBytes` to user code. The `==` operator must
normalize: extract bytes from both sides and compare structurally, regardless of
whether the underlying storage is NaN-boxed or heap-allocated.

### Concatenation Routing

`.concat` produces a new byte value routed through `new_bytes_value`. Results of
1-6 bytes are automatically immediate; 7+ go to heap. No special handling needed —
the constructor handles it.

## Display Formatting (`to_s`)

```gene
(println 0#ff)                # => 0#ff
(println 0#a0ff)              # => 0#a0ff
(println 0!11110000)          # => 0#f0
(println 0*AQID)              # => 0#010203
```

All byte values display as `0#` hex regardless of input format. This is a lossy
round-trip for binary and base64 literals — the original encoding is not preserved.
This is intentional: hex is the most readable universal representation for raw bytes.

The `to_s` format is always lowercase hex with `0#` prefix:

- 1 byte: `0#ab`
- 2 bytes: `0#abcd`
- 4 bytes: `0#abcd1234`
- 6 bytes: `0#abcd12345678`
- 7+ bytes: `0#abcd...` (first 8 bytes, then `...` if longer)

## Bytes Class and Methods

### Class Registration

Register `Bytes` class in stdlib (similar to Time class pattern):

```gene
(var b 0#ff)
(println (typeof b))          # => VkBytes
(println (b .size))           # => 1
(println (b .get 0))          # => 255
```

### Methods

| Method | Description | Example |
|--------|-------------|---------|
| `.size` | Number of bytes | `(0#abcd .size)` → 2 |
| `.get i` | Byte at index (0-based), returns int | `(0#ab .get 0)` → 171 |
| `[i]` | Same as `.get` (indexing) | `(0#ab .get 0)` → 171 |
| `.to_s` | Hex string representation | `(0#ff .to_s)` → `"0#ff"` |
| `.to_array` | Convert to array of ints | `(0#abcd .to_array)` → `[171 205]` |
| `.slice start end` | Sub-sequence (heap-allocated result) | `(0#abcd1234 .slice 1 3)` → `0#cd12` |
| `.concat other` | Concatenate two byte values | `(0#ab .concat 0#cd)` → `0#abcd` |

### String Interop

Existing methods continue to work:
- `("ABC" .bytes)` → bytes value
- Bytes → string: `(bytes .to_string)` (new, interprets as UTF-8)

## Compiler

Add `VkBytes` to `compile_literal` in `compiler.nim` — same pattern as the date/time
addition. Immediate byte values are stored directly in the instruction's arg field.

## Implementation Phases

### Phase 1: NaN-boxing infrastructure
- Add `BYTES_TAG`, `BYTES6_TAG` constants to `memory.nim`
- Update `new_bytes_value` constructor for immediate routing
- Add `bytes_len`, `bytes_at` extraction procs
- Update `kind` proc: add direct `BYTES_TAG` and `BYTES6_TAG` cases in the main
  `kind` proc (not `kind_slow`) — this is a hot path and should be fast
- Update `isManaged` — new tags are non-managed (already correct by tag range < FFF8)
- Update `$` / `to_s` for hex display
- Remove `VkBin`, `VkBin64`, `VkByte` from type_defs (unused)

### Phase 2: Parser
- Add `0x`/`0X` dispatch → new `parse_hex_int` proc (produces VkInt)
- Change `0*` dispatch to `0#` for hex bytes
- Change `0#` dispatch to `0*` for base64
- Wire `parse_bin`, `parse_hex`, `parse_base64` to return `new_bytes_value(bytes)`
- Fix `parse_bin` partial byte left-padding (right-shift by `8 - size mod 8`)
- Fix `parse_hex` error message copy-paste bug
- Add base64 input validation in `parse_base64`
- Remove VkByte/VkBin branching in parse procs
- Add `VkBytes` to compiler's `compile_literal`
- Uncomment and update parser tests (including `0x` integer tests)

### Phase 3: Bytes class and stdlib
- Register `Bytes` class in stdlib
- Implement `.size`, `.get`, `.to_array`, `.to_string`, `.slice`, `.concat`
- Ensure `[i]` indexing works for immediate bytes (update value_ops.nim)
- Equality: structural comparison for byte values
- Update `spec/02-types.md`

## Files to Modify

- `src/gene/types/memory.nim` — new BYTES_TAG, BYTES6_TAG constants
- `src/gene/types/type_defs.nim` — remove VkBin, VkBin64, VkByte
- `src/gene/types/reference_types.nim` — remove VkBin, VkBin64, VkByte cases
- `src/gene/types/core.nim` — `kind` proc update for new tags
- `src/gene/types/core/constructors.nim` — immediate-routing `new_bytes_value`
- `src/gene/types/core/value_ops.nim` — `$`, `[]`, `==`, `size` for immediate bytes
- `src/gene/parser.nim` — prefix routing, wire todo() stubs
- `src/gene/compiler.nim` — add VkBytes to compile_literal
- `src/gene/stdlib/` — Bytes class registration and methods
- `spec/02-types.md` — update bytes section
- `tests/test_parser.nim` — uncomment and update binary literal tests
