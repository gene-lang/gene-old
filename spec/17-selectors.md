# 17. Selectors

Selectors are Gene's unified data-access layer. They cover plain path lookup, dynamic segments, reusable selector values, stream-style selection over many matches, and simple mutation helpers.

## 17.1 Plain Path Access with `/`

The `/` operator reads members from composite values:

```gene
(var user {^name "Ada" ^profile {^lang "Gene"}})
(var nums [10 20 30])

user/name           # => "Ada"
user/profile/lang   # => "Gene"
nums/0              # => 10
nums/-1             # => 30
```

### Receiver Semantics

- Arrays accept positive and negative integer indices.
- Maps, namespaces, classes, instances, and Gene values accept key/member lookup.
- Missing keys/indices return `void`.
- Access on `nil` returns `nil`.

```gene
(var cfg {})
cfg/missing         # => void

(var x nil)
x/name              # => nil
```

## 17.2 Dynamic Segments with `<>`

Use `<>` when one segment is chosen at runtime:

```gene
(var key "name")
(var data {^name "Ada"})
data/<key>          # => "Ada"

(var idx 1)
(var people {^users [{^name "Ada"} {^name "Bob"}]})
people/users/<idx>/name   # => "Bob"
```

The expression inside `<>` contributes exactly one path segment.

## Selector behavior matrix

| Situation | Result |
|-----------|--------|
| Missing key, index, property, or child | `void` |
| Receiver is `nil` | `nil` |
| Default argument on `./` or selector call | Replaces only `void` |
| `/!` or selector `!` sees `void` | Throws |
| `/!` or selector `!` sees `nil` | Throws |
| Value stream `*` sees a `void` match | Drops that match |
| Entry stream `**` sees a `void` value | Drops that entry |

A default argument on `./` or selector call replaces only `void`; explicit
`nil` remains `nil`.

Stream value mode `*` drops `void` matches and collects remaining values into
an array. Stream entry mode `**` drops entries whose values are `void`; `@@`
collects remaining entries into a map.

## 17.3 Strict Access with `/!`

Append `!` to assert that the current result is not missing:

```gene
(var data {^user {^name "Ada"}})

data/user/!/name    # => "Ada"
data/user/name/!    # => "Ada"
```

If the asserted value is missing, evaluation throws.

```gene
(var cfg {})
cfg/port/!          # throws
```

This can appear mid-path or at the end of a path.

## 17.4 Selector Application with `./`

`./` is the explicit selector-call form:

```gene
({^a "A"} ./ "a")       # => "A"
({} ./ "a")              # => void
({} ./ "a" 1)            # => 1
```

Use it when the segment is already in a value position or when a default is needed.

## 17.5 Selector Values

Selectors are first-class values of their own runtime kind and can be stored, passed around, and called.

### Literal Constructor

```gene
(@ "name")
(@ "user" "profile" "lang")
```

### Shorthand Literals

```gene
@name
@user/profile/lang
@users/0/name
@users/*/name
```

### Applying a Selector

```gene
(var data {^users [{^name "Ada"} {^name "Bob"}]})

((@ "users" 0 "name") data)   # => "Ada"
(@users/*/name data)             # => ["Ada", "Bob"]

(var names @users/*/name)
(names data)                     # => ["Ada", "Bob"]
```

### Method Shorthand

Any object can apply a selector through `.@`:

```gene
(data .@users/0/name)            # => "Ada"
(data .@ "users" 1 "name")    # => "Bob"
```

## 17.6 Selection Mode

Selectors can switch from single-value lookup into stream-style traversal.

### `*` — expand values

`*` expands array elements or Gene children into a value stream.

```gene
(var data {^users [{^name "Ada"} {^name "Bob"}]})
(@users/*/name data)             # => ["Ada", "Bob"]
```

### `**` — expand entries

`**` expands keyed containers into key/value pairs.

Supported receivers include maps, namespaces, classes, instances, and Gene property maps.

```gene
(var data {^props {^x 1 ^y 2}})
(@props/** data)                 # => [["x" 1] ["y" 2]]
```

### `@` — collect values

Collect the current value stream into an array:

```gene
(@users/*/@ data)                # => [{^name "Ada"} {^name "Bob"}]
```

### `@@` — collect entries

Collect the current entry stream into a map:

```gene
((@ "props" ** @@) data)     # => {^x 1 ^y 2}
```

### End-of-selector reduction

If selector execution ends in stream mode:

- value streams are collected into an array
- entry streams are collected into an array of `[key value]` pairs unless `@@` is used

Missing matches are skipped while a selector is in stream mode.

## 17.7 Callable Segments

A selector path may include functions. The function receives the current match and returns the next value in the path.

```gene
((@ "a" (fn [v] (v + 1))) {^a 1})   # => 2
((@ "user" (fn [u] u/name)) {^user {^name "Ada"}})  # => "Ada"
```

In entry-stream mode, callable segments receive `key` and `value`.

Callable segments transform the selected value; they do not automatically write the result back into the original container.

## 17.8 Mutation with `$set`

`$set` accepts selector shorthand for simple updates:

```gene
(var user {^profile {^name "Ada"}})
($set user @profile {^name "Ada Lovelace"})
user/profile/name                # => "Ada Lovelace"
```

Current behavior is intentionally limited:

- `$set` supports exactly one selector segment for direct property or index updates
- shorthand expansion is ergonomic
- generalized multi-segment update/delete APIs are not yet specified

$set supports exactly one selector segment for map properties, Gene properties,
instance properties, array indices, and Gene child indices. Deep update and
delete behavior remains unspecified.

## 17.9 Interaction with `void` and `nil`

Selectors distinguish two important outcomes:

- `void` — the requested member/index is absent
- `nil` — the receiver itself is `nil`, so access propagates `nil`

Use `/!` when absence should become an error instead of a value.

---

## Potential Improvements

- **Ranges and slices**: No selector support yet for index ranges, slices, or lists of indices.
- **Predicate operators**: Callable segments can transform, but dedicated filter/predicate selector operators are still missing.
- **Gene-specific views**: Rich selector segments such as descendants, property keys, or property values are still design work.
- **Update breadth**: `$set` covers simple assignment only; update/delete/append operations over deep selectors remain unspecified.
- **Generator integration**: Selection mode currently works on materialized structures rather than lazy iterables.
- **Diagnostics**: `void` is compact but not always informative; stricter diagnostics or optional tracing would help debugging.
