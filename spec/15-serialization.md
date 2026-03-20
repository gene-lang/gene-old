# 15. Serialization

## 15.1 JSON (Plain)

Standard JSON conversion:

```gene
(gene/json/parse "{\"name\":\"Alice\",\"age\":30}")
# => {^name "Alice" ^age 30}

(gene/json/stringify {^name "Alice" ^age 30})
# => "{\"name\":\"Alice\",\"age\":30}"
```

### Type Mapping

| Gene Type | JSON Type   |
|-----------|-------------|
| Int       | number      |
| Float     | number      |
| String    | string      |
| Bool      | true/false  |
| Nil       | null        |
| Array     | array       |
| Map       | object      |

## 15.2 JSON (Tagged / Gene-Aware)

Round-trip serialization preserving Gene-specific types:

```gene
(gene/json/serialize value)      # Gene → tagged JSON
(gene/json/deserialize string)   # Tagged JSON → Gene
```

Tagged values use a `#GENE#` prefix:
- Symbols: `"#GENE#symbol_name"`
- Gene nodes: `{"genetype": "#GENE#type", "children": [...], ...props}`

## 15.3 GIR (Gene Intermediate Representation)

Binary format for compiled Gene bytecode:

```bash
# Compile to GIR
gene compile file.gene           # Writes to build/file.gir

# Run GIR directly (2-5× faster startup)
gene run build/file.gir

# Smart caching: auto-uses GIR if up-to-date
gene run file.gene               # Checks build/file.gir first
```

### GIR Contents
- Instruction sequences
- Constant pool
- Symbol table
- Type metadata (if type checking enabled)
- Debug info (if `--emit-debug`)
- Source hash (for cache invalidation)
- Compiler version (for compatibility)

### Cache Invalidation
GIR is invalidated when:
- Source file changes (hash mismatch)
- Compiler version changes
- `--no-gir-cache` flag is passed

## 15.4 Gene Serialization Format

Gene has its own text-based serialization using `gene ser` / `gene deser` commands:

```bash
gene ser '(+ 1 2)'     # Serialize Gene value to text
gene deser '<text>'     # Deserialize text back to Gene value
```

---

## Potential Improvements

- **Custom serialization hooks**: No way to define how user classes serialize/deserialize to JSON. Must manually implement conversion.
- **Binary serialization**: GIR is for bytecode only. No general-purpose binary serialization for Gene data structures.
- **YAML/TOML/XML**: No support for other common formats.
- **Streaming JSON**: Large JSON must be fully parsed into memory. No streaming/SAX-style parser.
- **Pretty printing**: `gene/json/stringify` produces compact output. No built-in pretty-print with indentation.
- **Serialization of functions**: Functions cannot be serialized. This limits what can be saved/transmitted.
- **GIR versioning**: GIR format changes require full recompilation. No migration path between GIR versions.
- **Circular reference handling**: JSON serialization does not detect circular references, which would cause infinite loops.
