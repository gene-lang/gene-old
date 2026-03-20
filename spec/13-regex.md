# 13. Regular Expressions

## 13.1 Regex Literals

```gene
(var re #/(\d+)/)
(var re_i #/pattern/i)      # Case-insensitive
(var re_m #/pattern/m)      # Multiline (. matches newline)
```

### With Replacement
```gene
(var re_sub #/(\d)/[\\1]/)   # Pattern + replacement in one literal
```

## 13.2 Matching

```gene
(var re #/(\d+)/)

# Match — returns RegexpMatch or nil
(re .match "abc123def")

# Process — same as match
(re .process "abc123def")

# Find — returns matched substring
(re .find "abc123def")       # => "123"

# Find all
(re .find_all "a1b2c3")     # => ["1", "2", "3"]

# Scan — non-overlapping matches
(re .scan "a1b2c3")
```

## 13.3 RegexpMatch Properties

```gene
(var m (#/(\w+)@(\w+)/ .match "user@host"))
m/.value            # => "user@host"
m/.captures         # => ["user", "host"]
m/.named_captures   # => {} (if no named groups)
m/.start            # Start offset (UTF-8 chars)
m/.end              # End offset (exclusive)
m/.pre_match        # Text before match
m/.post_match       # Text after match
```

## 13.4 Replacement

```gene
# Replace first
("hello world" .replace #/world/ "Gene")

# Replace all
("a1b2c3" .replace_all #/(\d)/ "[\\1]")   # => "a[1]b[2]c[3]"

# Aliases
("text" .sub #/pattern/ "replacement")      # Same as replace
("text" .gsub #/pattern/ "replacement")     # Same as replace_all
```

## 13.5 String Methods with Regex

```gene
("hello" .match #/h(.+)/)        # Returns RegexpMatch
("hello" .contain #/ell/)        # => true
("a,b,,c" .split #/,+/)          # => ["a", "b", "c"]
("hello" .find #/l+/)            # => "ll"
("abc123" .find_all #/\d/)       # => ["1", "2", "3"]
```

## 13.6 Regex Constructor

```gene
(var re (new gene/Regexp "pattern"))
(var re_i (new gene/Regexp ^^i "pattern"))      # Case-insensitive
(var re_im (new gene/Regexp ^^i ^^m "pattern")) # Multiple flags
```

---

## Potential Improvements

- **Named capture groups**: Named groups like `(?P<name>\w+)` should work but their accessibility through `.named_captures` is inconsistent.
- **Regex interpolation**: No way to build regex patterns from strings at runtime without using the constructor. A `#/#{pattern}/` form would help.
- **Global match state**: Regex objects don't maintain match position state for incremental matching.
- **Unicode categories**: No support for `\p{Letter}` Unicode property escapes in patterns.
- **Verbose mode**: No `x` flag for whitespace-insensitive patterns with comments.
- **Literal escaping**: Forward slashes inside `#/.../` need escaping (`\/`), which is inconvenient for URL patterns.
