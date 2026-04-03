# 14. Standard Library

## 14.1 I/O

### Print
```gene
(print "no newline")
(println "with newline")
```

### File I/O (Synchronous)
```gene
(var text (gene/io/read "file.txt"))
(gene/io/write "out.txt" "content")
```

### File I/O (Asynchronous)
```gene
(var text (await (gene/io/read_async "file.txt")))
(await (gene/io/write_async "out.txt" "content"))
```

## 14.2 String Methods

| Method           | Description                        | Example                                |
|------------------|------------------------------------|----------------------------------------|
| `.length`        | Character count                    | `("hello" .length)` => 5               |
| `.to_upper`      | Uppercase                          | `"hi" .to_upper` => "HI"              |
| `.to_lower`      | Lowercase                          | `"HI" .to_lower` => "hi"              |
| `.capitalize`    | Capitalize first char              | `"hi" .capitalize` => "Hi"            |
| `.reverse`       | Reverse string                     | `"abc" .reverse` => "cba"             |
| `.append`        | Concatenate                        | `("a" .append "b")` => "ab"           |
| `.start_with?`   | Prefix check                       | `("hello" .start_with? "he")` => true |
| `.include?`      | Contains (string or regex)         | `("hello" .include? "ell")` => true   |
| `.chars`         | Split to char array                | `"abc" .chars` => ["a","b","c"]       |
| `.char_at`       | Character at index                 | `("abc" .char_at 1)` => "b"           |
| `.split`         | Split by string or regex           | `("a,b,c" .split ",")` => ["a","b","c"] |
| `.contain`       | Contains (alias for include?)      | `("hi" .contain "h")` => true         |
| `.trim`          | Trim surrounding whitespace        | `(" hi " .trim)` => "hi"              |
| `.index`         | Find first index of string/regex   | `("abc" .index "b")` => 1             |
| `.find`          | Find first match                   | `("abc" .find #/b/)` => "b"           |
| `.find_all`      | Find all matches                   | `("a1b2" .find_all #/\d/)` => ["1","2"] |
| `.replace`       | Replace first occurrence           | `("aab" .replace "a" "x")` => "xab"  |
| `.replace_all`   | Replace all occurrences            | `("aab" .replace_all "a" "x")` => "xxb" |
| `.match`         | Regex match                        | `("abc" .match #/b/)` => RegexpMatch  |

Unicode-aware: `.capitalize`, `.reverse`, `.length` handle multi-byte characters correctly.

## 14.3 Array Methods

| Method     | Description                              |
|------------|------------------------------------------|
| `.size`    | Element count                            |
| `.length`  | Same as size                             |
| `.add`     | Append element (mutates)                 |
| `.get`     | Index access                             |
| `.pop`     | Remove and return last                   |
| `.each`    | Visit each element                       |
| `.find`    | Return first matching element            |
| `.map`     | Transform each element                   |
| `.filter`  | Keep elements matching predicate         |
| `.reduce`  | Fold with accumulator                    |
| `.zip`     | Pair items with another array            |
| `.sort`    | Sort values                              |
| `.reverse` | Reverse element order                    |
| `.slice`   | Return a sub-array                       |

## 14.4 Map Methods

| Method     | Description                              |
|------------|------------------------------------------|
| `.size`    | Key count                                |
| `.get`     | Lookup by key                            |
| `.contains`| Check key existence                      |
| `.keys`    | Return keys as an array                  |
| `.values`  | Return values as an array                |
| `.each`    | Visit entries                            |
| `.map`     | Transform entries                        |
| `.filter`  | Keep entries matching predicate          |
| `.reduce`  | Fold with accumulator                    |
| `.merge`   | Merge another map into this one          |

## 14.5 Math

```gene
(abs -5)        # => 5
(sqrt 16)       # => 4.0
(pow 2 10)      # => 1024
(min 3 7)       # => 3
(round 3.6)     # => 4
(random)        # => implementation-defined float
```

## 14.6 Environment

```gene
$env/HOME              # Read env var
(set_env "KEY" "val")  # Set env var
(has_env "KEY")        # Check existence
```

## 14.7 Date and Time

### Constructors
```gene
(println (typeof (gene/today)))
(println (typeof (gene/yesterday)))
(println (typeof (gene/tomorrow)))
(println (typeof (gene/now)))
# => VkDate
# => VkDate
# => VkDate
# => VkDateTime
```

### Accessors

Supported accessors are:

| Type | Accessors |
|------|-----------|
| `Date` | `.year`, `.month`, `.day` |
| `DateTime` | `.year`, `.month`, `.day`, `.hour`, `.minute`, `.second`, `.to_i` |

```gene
(var d (gene/today))
(println ((d .year) > 2000))
(println (((d .month) >= 1) && ((d .month) <= 12)))
(println (((d .day) >= 1) && ((d .day) <= 31)))

(var dt (gene/now))
(println (((dt .hour) >= 0) && ((dt .hour) < 24)))
(println (((dt .minute) >= 0) && ((dt .minute) < 60)))
(println (((dt .second) >= 0) && ((dt .second) < 60)))
(println ((dt .to_i) > 0))
# => true
# => true
# => true
# => true
# => true
# => true
# => true
```

### Formatting

Printing is the currently exposed formatting API:

- `Date` renders as `YYYY-M-D`
- `DateTime` renders as `YYYY-M-D H:M:S`

### Parsing, Arithmetic, and Timezones

- No date or datetime parsing API is currently exposed.
- No date arithmetic API is currently exposed.
- No timezone accessor or conversion API is currently exposed.
- `DateTime` stores timezone data internally, but the current Gene surface only exposes the accessors above plus `.to_i`.

## 14.8 Bytes

Byte-oriented helpers currently hang off `String`. They produce `VkBytes` values, but Bytes itself is still mostly opaque to Gene code.

### String Byte Helpers
```gene
(println ("hé" .bytesize))
(println (typeof ("ABC" .bytes)))
(println ("ABC" .each_byte))
(println ("hé" .byteslice 0 1))
# => 3
# => VkBytes
# => [65 66 67]
# => VkBytes
```

Aliases:

- `.bytes` and `.to_bytes` are equivalent
- `.byteslice` and `.byte_slice` are equivalent

Standalone binary, hex, and base64 literals are not yet fully user-facing even though the runtime has `VkBytes`, `VkByte`, and related internal types.

## 14.9 JSON

```gene
# Plain JSON
(gene/json/parse "{\"a\":1}")          # => {^a 1}
(gene/json/stringify {^a 1})           # => "{\"a\":1}"

# Tagged (Gene-aware, round-trip safe)
(gene/json/serialize value)            # Gene value → JSON with #GENE# tags
(gene/json/deserialize json_string)    # JSON with #GENE# tags → Gene value
```

## 14.10 Base64

```gene
(gene/base64_encode "hello")    # => "aGVsbG8="
(gene/base64_decode "aGVsbG8=") # => "hello"
```

## 14.11 Assertions

```gene
(assert (x > 0))
(assert (x > 0) "x must be positive")
```

## 14.12 HTTP Client

```gene
(var resp (await (http_get "https://example.com")))
resp/status    # HTTP status code
resp/body      # Response body string
resp/headers   # Response headers

(await (http_post url body))
# Also: http_put, http_patch, http_delete
```

## 14.13 HTTP Server

```gene
(start_server 8080 (fn [req]
  (respond 200 "Hello!")))
(run_forever)
```

Request properties: `method`, `path`, `url`, `params`, `headers`, `body`

## 14.14 Database Clients

### SQLite
```gene
(var db (genex/sqlite/open "/path/to/db.sqlite"))
(db .query "SELECT * FROM users WHERE age > ?" 18)
(db .exec "INSERT INTO users (name) VALUES (?)" "Alice")
(db .close)
```

### PostgreSQL
```gene
(var pg (genex/postgres/open "host=localhost dbname=mydb"))
(pg .query "SELECT * FROM users WHERE id = $1" 42)
(pg .exec "INSERT INTO users (name) VALUES ($1)" "Alice")
(pg .begin)
(pg .commit)    # or (pg .rollback)
(pg .close)
```

Results: arrays of arrays `[[col1 col2] [col1 col2] ...]`

## 14.15 System & Processes

```gene
(cwd)

(var p (system/Process/start "echo" "hello"))
(var line (p .read_line ^timeout 5))
(var code (p .wait ^timeout 5))
```

`system/Process` is currently supported on Unix/macOS. The `system/` namespace also exposes helpers such as `exec`, `shell`, `cwd`, `cd`, `args`, `os`, and `arch`.

---

## Potential Improvements

- **String methods consistency**: Some use `?` suffix (`.start_with?`, `.include?`), others don't (`.contain`). Standardize naming.
- **Missing string methods**: No `.pad_left`, `.pad_right`, `.repeat`, or richer substring/slice variants beyond `.index` and `.trim`.
- **Missing array methods**: No `.flatten`, `.any?`, `.all?`, `.index_of`, `.insert`, or `.remove_at`.
- **Missing map methods**: No dedicated `.entries`, `.has_key?` alias, or `.delete` helper.
- **Functional utilities**: No `compose`, `partial`, `identity`, `constantly` built-ins.
- **Math library**: Core helpers include `min`, `max`, `floor`, `ceil`, `round`, and `random`, but trig/log functions are still absent.
- **Date/time**: Core constructors and accessors exist, but there is still no direct Date/DateTime literal construction, parsing API, arithmetic API, or timezone control.
- **Bytes**: `VkBytes` exists and string byte helpers work, but raw Bytes values remain mostly opaque and there is no complete standalone bytes API yet.
- **File system**: No directory listing, file existence check, path manipulation, or file metadata.
- **Process/system**: `system/Process`, `system/exec`, and `system/shell` exist, but process support is still Unix/macOS-focused and there is no richer filesystem/process management layer yet.
- **Networking**: HTTP exists but no raw TCP/UDP sockets exposed to Gene code.
- **Logging**: Structured logging exists via `genex/logging`, but it is not part of the core prelude documented in this section.
