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
| `.length`        | Character count                    | `"hello"/.length` => 5                 |
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
| `.map`     | Transform each element                   |
| `.filter`  | Keep elements matching predicate         |
| `.reduce`  | Fold with accumulator                    |

## 14.4 Map Methods

| Method     | Description                              |
|------------|------------------------------------------|
| `.size`    | Key count                                |
| `.get`     | Lookup by key                            |
| `.contains`| Check key existence                      |
| `.map`     | Transform entries                        |
| `.filter`  | Keep entries matching predicate          |
| `.reduce`  | Fold with accumulator                    |

## 14.5 Math

```gene
(abs -5)        # => 5
(sqrt 16)       # => 4.0
(pow 2 10)      # => 1024
```

## 14.6 Environment

```gene
$env/HOME              # Read env var
(set_env "KEY" "val")  # Set env var
(has_env "KEY")        # Check existence
```

## 14.7 Time

```gene
(gene/time/now)    # Current time (milliseconds)
```

## 14.8 JSON

```gene
# Plain JSON
(gene/json/parse "{\"a\":1}")          # => {^a 1}
(gene/json/stringify {^a 1})           # => "{\"a\":1}"

# Tagged (Gene-aware, round-trip safe)
(gene/json/serialize value)            # Gene value → JSON with #GENE# tags
(gene/json/deserialize json_string)    # JSON with #GENE# tags → Gene value
```

## 14.9 Base64

```gene
(gene/base64_encode "hello")    # => "aGVsbG8="
(gene/base64_decode "aGVsbG8=") # => "hello"
```

## 14.10 Assertions

```gene
(assert (x > 0))
(assert (x > 0) "x must be positive")
```

## 14.11 HTTP Client

```gene
(var resp (await (http_get "https://example.com")))
resp/status    # HTTP status code
resp/body      # Response body string
resp/headers   # Response headers

(await (http_post url body))
# Also: http_put, http_patch, http_delete
```

## 14.12 HTTP Server

```gene
(start_server 8080 (fn [req]
  (respond 200 "Hello!")))
(run_forever)
```

Request properties: `method`, `path`, `url`, `params`, `headers`, `body`

## 14.13 Database Clients

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

---

## Potential Improvements

- **String methods consistency**: Some use `?` suffix (`.start_with?`, `.include?`), others don't (`.contain`). Standardize naming.
- **Missing string methods**: No `.trim`, `.pad_left`, `.pad_right`, `.repeat`, `.index_of`, `.substring` (or `.slice`).
- **Missing array methods**: No `.sort`, `.reverse`, `.flatten`, `.zip`, `.each`, `.find`, `.any?`, `.all?`, `.index_of`, `.insert`, `.remove_at`, `.slice`.
- **Missing map methods**: No `.keys`, `.values`, `.entries`, `.merge`, `.has_key?`, `.delete`.
- **Functional utilities**: No `compose`, `partial`, `identity`, `constantly` built-ins.
- **Math library**: Very limited. Missing: `min`, `max`, `floor`, `ceil`, `round`, `sin`, `cos`, `log`, `random`.
- **Date/time**: Only `now` exists. No date parsing, formatting, arithmetic, or timezone support.
- **File system**: No directory listing, file existence check, path manipulation, or file metadata.
- **Process/system**: No way to spawn system processes or run shell commands.
- **Networking**: HTTP exists but no raw TCP/UDP sockets exposed to Gene code.
- **Logging**: No structured logging facility. Only `print`/`println`.
