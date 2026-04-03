# 13. Regular Expressions

## 13.1 Regex Literals

```gene
(println #/(\d+)/)
(println #/pattern/i)
(println #/line.*/m)
# => #/(\d+)/
# => #/pattern/i
# => #/line.*/m
```

### With Replacement
```gene
(println #/(\d)/[\\1]/)
(println ("a1b2" .replace #/(\d)/[\\1]/))
(println ("a1b2" .replace_all #/(\d)/[\\1]/))
# => #/(\d)/[\1]/
# => a[1]b2
# => a[1]b[2]
```

## 13.2 Matching

```gene
(var re #/(\d+)/)

# Match — returns RegexpMatch or nil
(println (re .match "abc123def"))

# Process — same as match
(println (re .process "abc123def"))

# Find — returns matched substring
(println (re .find "abc123def"))

# Find all
(println (re .find_all "a1b2c3"))

# Scan — non-overlapping matches
(println (re .scan "a1b2c3"))
# => VkRegexMatch
# => VkRegexMatch
# => 123
# => [1 2 3]
# => [1 2 3]
```

## 13.3 Capture Groups and Match Data

```gene
(var m (#/(?P<user>\w+)@(?P<host>\w+)/ .match "say user@host now"))
(println m/value)
(println m/captures)
(println m/named_captures)
(println m/start)
(println m/end)
(println m/pre_match)
(println m/post_match)
# => user@host
# => [user host]
# => {^user user ^host host}
# => 4
# => 13
# => say 
# =>  now
```

`m/start` and `m/end` are UTF-8 character offsets, with `end` exclusive.

## 13.4 Replacement

```gene
# Replace first
(println ("hello world" .replace #/world/ "Gene"))

# Replace all
(println ("a1b2c3" .replace_all #/(\d)/ "[\\1]"))

# Aliases
(println ("text" .sub #/e/ "E"))
(println ("text" .gsub #/t/ "T"))
(println ("alice@example" .replace #/(?P<user>\w+)@(?P<host>\w+)/ "<\\k<user>>"))
# => hello Gene
# => a[1]b[2]c[3]
# => tExt
# => TexT
# => <alice>
```

## 13.5 String Methods with Regex

```gene
(println ("hello" .match #/h(.+)/))
(println ("hello" .contain #/ell/))
(println ("a,b,,c" .split #/,+/))
(println ("hello" .find #/l+/))
(println ("abc123" .find_all #/\d/))
# => VkRegexMatch
# => true
# => [a b c]
# => ll
# => [1 2 3]
```

## 13.6 Regex Constructor

```gene
(println (new Regexp "pattern"))
(println (new Regexp ^^i "pattern"))
(println (new Regexp ^^i ^^m "line.*"))
# => #/pattern/
# => #/pattern/i
# => #/line.*/im
```

Gene does not use a separate `g` flag. Global behavior comes from the collection-style methods: `.find_all`, `.scan`, and `.replace_all`.

---

## Potential Improvements

- **Regex interpolation**: No way to build regex patterns from strings at runtime without using the constructor. A `#/#{pattern}/` form would help.
- **Global match state**: Regex objects don't maintain match position state for incremental matching.
- **Unicode categories**: No support for `\p{Letter}` Unicode property escapes in patterns.
- **Verbose mode**: No `x` flag for whitespace-insensitive patterns with comments.
- **Literal escaping**: Forward slashes inside `#/.../` need escaping (`\/`), which is inconvenient for URL patterns.
