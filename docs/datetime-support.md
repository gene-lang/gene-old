# Date, DateTime, and Time Literal Support

## Motivation

Gene has the type infrastructure for dates and times (`VkDate`, `VkDateTime`, `VkTime`,
`VkTimezone`) and runtime constructors (`gene/today`, `gene/now`), but no literal syntax.
The parser recognizes the token shapes and hits `todo()` stubs in `read_number()`
(`parser.nim` — the `of '-':` branch at line 1533 has `todo("date")` at 1542 and
`todo("datetime")` at 1538; the `of ':'` branch at line 1543 has `todo("time")` at
1550). This document specifies the literal forms, their semantics, and the type system
changes needed to complete the feature.

## Standards

All literal forms follow established standards:

- **ISO 8601** — date and time representation
- **RFC 3339** — internet timestamp format (profile of ISO 8601)
- **RFC 9557** — extended date/time format with IANA timezone brackets
  (adopted by Java `ZonedDateTime` and TC39 Temporal)
- **IANA Time Zone Database** — canonical timezone identifiers (`America/New_York`)

### Design Decisions

**No timezone abbreviations.** EDT, PST, CST are **not supported** in literals because
they are ambiguous — CST alone maps to US Central, China Standard, and Cuba Standard
(14 hours apart).

**4-digit years only.** Two-digit years (e.g., `24-01-02`) are rejected. The truncated
form was removed from ISO 8601 in the 2004 revision due to Y2K-era ambiguity.

**Offset required before bracket notation.** Following RFC 9557, `[Zone/Name]` must be
preceded by a UTC offset or `Z`. Writing `2024-01-23T10:00[America/New_York]` without
an offset is a parse error — write `2024-01-23T10:00-05:00[America/New_York]` instead.
This keeps parsing deterministic and avoids requiring timezone database access at parse
time. The one exception is bare time literals (see below).

**`T` separator required.** No space variant (`2024-01-23 20:10:10`) — the `T` keeps
parsing unambiguous in S-expression context where spaces delimit tokens.

## Literal Forms

### Date

```gene
2024-01-23                    # Date (VkDate)
```

Format: `YYYY-MM-DD`. Always exactly 4-2-2 digits.

### DateTime

```gene
2024-01-23T20:10              # Naive, hour:minute only
2024-01-23T20:10:10           # Naive datetime (no timezone)
2024-01-23T20:10:10.123       # With fractional seconds (milliseconds)
2024-01-23T20:10:10.123456    # With fractional seconds (microseconds)
2024-01-23T20:10:10Z          # UTC
2024-01-23T20:10:10+05:00     # With UTC offset
2024-01-23T20:10:10-08:00     # Negative offset
2024-01-23T20:10:10+05:00[Asia/Kolkata]          # Offset + IANA zone (RFC 9557)
2024-01-23T20:10:10Z[America/New_York]           # UTC + IANA zone
```

Seconds are optional (default to 0). Fractional seconds support 1-6 digits
(milliseconds to microseconds).

The bracket `[Zone/Name]` **must** be preceded by an offset or `Z`. This avoids
requiring timezone database access at parse time.

### Time

```gene
10:10                         # Hour:minute
10:10:10                      # Hour:minute:second
10:10:10.123                  # With fractional seconds
10:10:10Z                     # UTC
10:10:10+05:00                # With offset
10:10:10[America/New_York]    # With IANA zone (for recurring events)
```

Format: `HH:MM[:SS[.fraction]][timezone]`. Hours are 0-23 (24-hour clock).

**Exception to the offset-before-bracket rule:** Bare time literals allow
`[Zone/Name]` without a preceding offset because there is no date to resolve
against — the offset is deferred to when the time is combined with a date.

### Timezone on Time: Why It Matters

A bare time with a fixed offset (`10:10+05:00`) is unambiguous but breaks for
recurring events across DST transitions:

```gene
# "Daily standup at 10:00 New York time"
# Winter: 10:00-05:00 (EST)
# Summer: 10:00-04:00 (EDT)

# Wrong — shifts by 1 hour in summer:
(var standup 10:00-05:00)

# Correct — offset resolved when combined with a date:
(var standup 10:00[America/New_York])
```

When a zoned time is combined with a date, the IANA zone rules determine the
correct offset for that specific date.

### Parser Disambiguation

Gene is an S-expression language where spaces delimit tokens. This makes literal
detection straightforward:

```gene
2024-01-23          # No spaces → date literal
(- 2024 1 23)       # Spaces → subtraction expression
(2024 - 1 - 23)     # Spaces → subtraction expression

10:10:10            # No spaces → time literal
(foo 10:10)         # Still a time literal (no space within 10:10)
```

The parser enters date/time mode based on what follows a leading integer:
- `-` (no space) → date parsing path
- `:` (no space) → time parsing path
- space, `)`, `]`, `}`, EOF → plain integer

## Type System

### Current State

Defined in `src/gene/types/reference_types.nim`:

```
VkDate:     date_year (int16), date_month (int8), date_day (int8)
VkDateTime: dt_year (int16), dt_month (int8), dt_day (int8),
            dt_hour (int8), dt_minute (int8), dt_second (int8),
            dt_timezone (int16)
VkTime:     time_hour (int8), time_minute (int8), time_second (int8),
            time_microsecond (int32)
VkTimezone: tz_offset (int16), tz_name (string)
```

Note: These are cases in Nim's `Reference` discriminated union. Adding fields to a
case branch does not increase the size of other branches — only the largest branch
determines the union size. Adding a string field (pointer-sized) to VkDateTime and
VkTime is safe.

### Required Changes

**VkDateTime** needs:
- `dt_microsecond: int32` — for fractional seconds (currently missing)
- `dt_tz_name: string` — for IANA zone name (currently only stores offset as int16)

**VkTime** needs:
- `time_tz_offset: int16` — for fixed offset in minutes (currently missing)
- `time_tz_name: string` — for IANA zone name (currently missing)

The existing `dt_timezone` field (int16, offset in minutes) is retained. When both
offset and IANA name are present, both are stored. The offset is the canonical value
for instant calculation; the name is metadata for DST-aware operations.

**Constructor note:** The current `new_datetime_value(dt: DateTime)` in
`constructors.nim` takes a Nim `times.DateTime` and computes the offset via
`dt.utcOffset div 60`. This path cannot carry microseconds or IANA zone names.
A new overload is needed: `new_datetime_value(year, month, day, hour, minute,
second, microsecond, offset_minutes, tz_name)` that populates fields directly
from parsed literal components. The existing Nim DateTime-based constructor is
retained for `gene/now` and other stdlib functions that go through Nim's `times`
module.

### Timezone Resolution Strategy

Since we require offset before bracket notation on DateTime literals, the parser
never needs timezone database access:

1. **DateTime with offset only** (e.g., `2024-01-23T10:00+05:00`):
   Offset stored in `dt_timezone`. `dt_tz_name` is empty.

2. **DateTime with offset + zone name** (e.g., `2024-01-23T10:00-05:00[America/New_York]`):
   Offset stored in `dt_timezone`. Zone name stored in `dt_tz_name`. No resolution
   needed — the user provided both.

3. **DateTime with `Z` + zone name** (e.g., `2024-01-23T15:00Z[America/New_York]`):
   Offset = 0 (UTC). Zone name stored. This represents "the UTC instant is 15:00,
   and the intended timezone is New York." Conversion to local time is a runtime
   operation.

4. **Time with zone name** (e.g., `10:00[America/New_York]`): This is the exception
   that allows bracket without offset. `time_tz_offset` is left at 0 (unresolved).
   `time_tz_name` stores the zone name. Offset is resolved when combined with a
   date at runtime via `.at`.

**Nim dependency**: Nim's `times` module only provides `utc()` and `local()`. Full IANA
timezone resolution (for `.at`, `.to_utc`, DST arithmetic) requires either bundling
tzdata or using OS facilities (`/usr/share/zoneinfo` on Unix). This is a runtime
concern, not a parser concern. For the initial implementation, IANA names are stored
as strings and operations that need resolution use the OS timezone database where
available.

## Parser Changes

All changes are in `src/gene/parser.nim`, replacing the `todo()` stubs in
`read_number()` (the `of '-':` branch at line 1533 and `of ':'` branch at line 1543).

### Parsing Flow

**After reading leading digits and hitting `-` (line 1533):**
1. Read ahead greedily: `YYYY-MM-DD`
2. Validate: exactly 4-2-2 digits with `-` separators
3. Check next char:
   - Terminator (space, `)`, `]`, `}`, EOF) → **VkDate**
   - `T` → consume `T`, parse time portion → **VkDateTime**
   - Anything else → **ParseError**

**After reading leading digits and hitting `:` (line 1543):**
1. Read ahead: `HH:MM` (already have HH, read `:MM`)
2. Check for seconds: `:SS` (optional)
3. Check for fractional seconds: `.` followed by 1-6 digits
4. Check for timezone suffix:
   - `Z` → UTC offset
   - `+` or `-` → read `HH:MM` offset
   - `[` → read IANA zone name until `]` (bare time exception)
5. → **VkTime**

**DateTime time portion (after `T`):**
1. Read `HH:MM` (required)
2. Check for seconds: `:SS` (optional, default 0)
3. Check for fractional seconds: `.` followed by 1-6 digits
4. Check for timezone suffix:
   - `Z` → UTC (offset = 0), then optionally `[Zone/Name]`
   - `+` or `-` → read `HH:MM` offset, then optionally `[Zone/Name]`
   - `[` without offset → **ParseError** (offset required before bracket on DateTime)
   - Terminator → naive DateTime (no timezone)

### Validation

Validated at parse time. Invalid values raise `ParseError`:
- Month: 1-12
- Day: 1-31 (no calendar validation — `2024-02-30` parses but is semantically wrong)
- Hour: 0-23
- Minute: 0-59
- Second: 0-59 (no leap second support)
- Offset hours: -23 to +23, offset minutes: 0-59
- Fractional seconds: 1-6 digits (padded with trailing zeros to microseconds)
- IANA zone name: non-empty, contains `/`, no validation against database at parse time

## Canonical String Representation (`to_s`)

Literals round-trip through `to_s` — printing a parsed literal produces the same
string form (minus insignificant variations like trailing fractional zeros).

| Type | `to_s` output |
|------|---------------|
| Date | `2024-01-23` |
| DateTime (naive) | `2024-01-23T20:10:10` |
| DateTime (with microseconds) | `2024-01-23T20:10:10.123000` (trailing zeros trimmed → `.123`) |
| DateTime (UTC) | `2024-01-23T20:10:10Z` |
| DateTime (offset) | `2024-01-23T20:10:10+05:00` |
| DateTime (offset + zone) | `2024-01-23T20:10:10+05:00[Asia/Kolkata]` |
| Time | `10:10:10` |
| Time (HH:MM only) | `10:10` |
| Time (with zone) | `10:10:10[America/New_York]` |

Fractional seconds: trailing zeros are trimmed (`.123000` → `.123`). If all
fractional digits are zero, the `.` is omitted entirely.

**Current `to_s` output (before this work):** The existing formatting in
`value_ops.nim` outputs `2024-1-23 20:10:10` — no zero-padding, space separator
instead of `T`. Implementation must change this to ISO 8601 format with zero-padded
fields and `T` separator.

## Stdlib Additions

### Constructors

```gene
(Date 2024 1 23)                          # Explicit constructor
(DateTime 2024 1 23 20 10 10)             # Without timezone
(Time 10 10 10)                           # Explicit constructor
```

### Combination

```gene
# Combine date + zoned time → zoned datetime
(var d 2024-07-15)
(var t 10:00[America/New_York])
(var dt (d .at t))                        # → 2024-07-15T10:00:00-04:00[America/New_York]

(var d2 2024-01-15)
(var dt2 (d2 .at t))                      # → 2024-01-15T10:00:00-05:00[America/New_York]
```

### Accessors

Already implemented for Date and DateTime classes in `src/gene/stdlib/dates.nim`:
`.year`, `.month`, `.day`, `.hour`, `.minute`, `.second`, `.to_i`, `.to_s`

**Note:** There is currently no `Time` class registered in the stdlib. `dates.nim`
defines `Date` and `DateTime` classes with methods, but `Time` has no class, no
methods, and no constructor exposed to Gene code. Phase 2 must create the Time class
from scratch (register class, define accessors, add to gene_ns/global_ns).

Additions needed for all three types:
- `.microsecond` — fractional seconds
- `.offset` — timezone offset in minutes (nil for naive)
- `.timezone` — timezone name string (nil if no IANA zone)
- `.to_utc` — convert to UTC datetime (requires offset)
- `.to_epoch` — alias for `.to_i` (milliseconds since Unix epoch)

### Comparison

Dates and times support ordering and equality:

```gene
(< 2024-01-01 2024-12-31)                # → true
(== 2024-01-23 2024-01-23)               # → true
(> 10:30 10:00)                           # → true
```

**DateTime comparison rules:**
- Naive datetimes compare field-by-field (year, month, day, hour, minute, second, microsecond)
- Offset datetimes normalize to UTC before comparing
- Comparing naive vs offset datetime raises an error (ambiguous)

### Arithmetic (future work)

```gene
# Duration = fixed elapsed time (seconds-based)
# Period = calendar units (year/month/day, DST-aware)

(+ 2024-01-23 (Duration ^days 5))        # → 2024-01-28
(+ 2024-01-31 (Period ^months 1))         # → 2024-02-29 (leap year)
(- 2024-01-28 2024-01-23)                 # → Duration of 5 days
```

Duration vs Period distinction matters: adding 1 month to Jan 31 yields Feb 28/29,
not "Feb 31." Duration arithmetic uses fixed seconds; Period arithmetic uses
calendar rules and is DST-aware when a timezone is present.

## Implementation Phases

### Phase 1: Date and naive DateTime literals
- Add `dt_microsecond` field to VkDateTime in `reference_types.nim`
- Update `new_datetime_value` constructor for microsecond field
- Wire `todo("date")` → parse `YYYY-MM-DD`, validate, call `new_date_value()`
- Wire `todo("datetime")` → parse `YYYY-MM-DDTHH:MM[:SS[.fraction]]`
- Update `to_s` for Date and DateTime in `value_ops.nim`
- Tests for date and naive datetime forms

### Phase 2: Time literals
- Add `time_tz_offset` and `time_tz_name` fields to VkTime in `reference_types.nim`
- Update `new_time_value` constructor
- Wire `todo("time")` → parse `HH:MM[:SS[.fraction]]`
- Update `to_s` for Time in `value_ops.nim`
- Tests for all time forms

### Phase 3: Timezone support (on DateTime and Time)
- Add `dt_tz_name` to VkDateTime in `reference_types.nim`
- Parse `Z`, `+HH:MM`, `-HH:MM` suffixes on both DateTime and Time
- Parse `[Zone/Name]` bracket notation
- Store IANA names as strings (defer full resolution to runtime)
- Update `to_s` to include offset and bracket notation
- Tests for all timezone forms

### Phase 4: Stdlib and operations
- `.at` combination method (date + time → datetime)
- `.microsecond`, `.offset`, `.timezone` accessors
- `.to_utc` conversion
- Comparison operators for Date, DateTime, Time
- Update `spec/02-types.md`

### Phase 5 (future): Duration/Period arithmetic
- Duration type (fixed seconds)
- Period type (calendar units)
- DST-aware arithmetic with IANA zones
- OS timezone database integration

## Files to Modify

- `src/gene/types/reference_types.nim` — add fields to VkDateTime, VkTime
- `src/gene/types/core/constructors.nim` — update constructors for new fields
- `src/gene/types/core/value_ops.nim` — `$` / `to_s` formatting with timezone
- `src/gene/parser.nim` — replace `todo()` stubs with parsing logic
- `src/gene/stdlib/dates.nim` — new accessors, methods, comparison
- `spec/02-types.md` — update spec to reflect implemented literals
- `testsuite/` — new test files for date/time/datetime literals
