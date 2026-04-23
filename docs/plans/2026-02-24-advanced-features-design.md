# Advanced Features Design

## Goal

Add seven features to FixedWidthParsers.jl: FWBool, custom trim/pad on numerics, default values, post-parse transforms, schema visualization, multi-record types, and @generated specialization.

## Implementation Order

Features are ordered by dependency — each builds on the previous:

1. FWBool
2. Custom trim/pad on FWInt/FWFloat
3. Default values (`:default` error mode)
4. Post-parse transforms
5. Schema visualization
6. Multi-record types
7. @generated specialization

---

## Feature 1: FWBool

New descriptor with configurable true/false string values.

### API

```julia
struct FWBool
    true_val::String
    false_val::String
    default::Union{Bool, Nothing}
    transform::Union{Function, Nothing}
end
FWBool(; true_val="Y", false_val="N", default=nothing, transform=nothing)
```

`default` and `transform` fields are included from the start (used by Features 3 and 4) but initially unused.

### Parsing

`parse_field(::FWBool, buf, pos, len)`:
- Strip leading/trailing whitespace from the field bytes
- Compare against `true_val` → return `true`
- Compare against `false_val` → return `false`
- Mismatch → `ArgumentError`

### Integration Points

- `_julia_type(::FWBool) = Bool`
- `_parse_type_string("Bool")` → `FWBool()`
- `_parse_type_string("Bool(T,F)")` → `FWBool("T", "F")`
- `_type_to_descriptor(::Type{Bool}) = FWBool()`
- `@fixedwidth` supports `field::Bool = 1`

---

## Feature 2: Custom Trim/Pad on Numeric Types

Extend FWInt and FWFloat with a `pad` character, matching FWString's existing pattern.

### API

```julia
struct FWInt
    pad::Char
    default::Union{Int, Nothing}
    transform::Union{Function, Nothing}
end
FWInt(; pad::Char=' ', default=nothing, transform=nothing)

struct FWFloat
    pad::Char
    default::Union{Float64, Nothing}
    transform::Union{Function, Nothing}
end
FWFloat(; pad::Char=' ', default=nothing, transform=nothing)
```

`default` and `transform` fields included from the start for Features 3 and 4.

### Parsing

For non-space pads, replace pad bytes with spaces before passing to `_parse_int_bytes` / `_parse_float_bytes`. The existing parsers already handle space-padded input.

### Affected Descriptors Summary

After Features 1-2, all mutable descriptors carry `pad` (where applicable), `default`, and `transform`:

| Descriptor | pad | default | transform |
|-----------|-----|---------|-----------|
| FWString | `' '` | nothing | nothing |
| FWInt | `' '` | nothing | nothing |
| FWFloat | `' '` | nothing | nothing |
| FWBool | — | nothing | nothing |
| FWDate | — | nothing | nothing |
| FWFixedPoint | — | nothing | nothing |
| FWSkip | — | — | — |

---

## Feature 3: Default Values (`:default` Error Mode)

New error mode alongside `:strict` and `:lenient`.

### Behavior

| Field content | `:strict` | `:lenient` | `:default` |
|--------------|-----------|------------|------------|
| Valid data | Parsed value | Parsed value | Parsed value |
| All-whitespace/blank | ParseError | `missing` | Default value (or ParseError if no default) |
| Malformed data | ParseError | `missing` + warning | ParseError |

### Blank Detection

A field is "blank" when all bytes are the descriptor's pad character (space by default). This is checked before `parse_field` is called.

### Column Types

- `:strict` → `Vector{T}` (as today)
- `:lenient` → `Vector{Union{T, Missing}}` (as today)
- `:default` → `Vector{T}` (defaults are concrete values, no Missing needed)

When a descriptor has no default set (`default=nothing`), blank fields in `:default` mode throw `ParseError` just like `:strict`.

### Implementation

Add `_is_blank(buf, pos, len, pad_byte)` helper. In `_fill_column!` and `_safe_parse_field`, check blank before parse when `on_error === :default`.

---

## Feature 4: Post-Parse Transforms

Each descriptor's `transform` field holds an optional function applied after parsing.

### API

```julia
schema = FixedWidthSchema(
    :code   => (3, FWString(; transform=uppercase)),
    :amount => (8, FWFloat(; transform=x -> round(x, digits=2))),
    :active => (1, FWBool(; transform=!)),
)
```

### Application Points

Transform runs after `parse_field` returns, before the value enters the column:

1. `_safe_parse_field` — row-oriented path
2. `_fill_column!` — columnar path
3. `_fill_column_strict!` / `_fill_column_lenient!` — generic columnar fill

### Type Implications

- `transform === nothing` → column type is `_julia_type(descriptor)` (as today)
- `transform !== nothing` → column type is `Any`

### Interactions

- Transform is applied to default values too (`:default` mode returns `transform(default)`)
- Transform is NOT applied to `missing` (`:lenient` mode)
- Transform errors are treated as parse errors (ParseError in strict/default, missing in lenient)

---

## Feature 5: Schema Visualization

Override `Base.show` for `FixedWidthSchema`.

### Compact Display

```
FixedWidthSchema(12 bytes, 4 fields, 3 output)
```

### Multi-line REPL Display

```
FixedWidthSchema (12 bytes, 4 fields, 3 output)
 Bytes  Width  Name     Type
  1:2       2  carrier  FWString
  3:6       4  fnum     FWInt
  7:9       3  _skip    FWSkip
 10:12      3  origin   FWString
```

### Type Formatting

- Non-default parameters shown: `FWString(pad='0')`, `FWBool("T","F")`, `FWDate("yyyymmdd")`, `FWInt(default=0)`
- Transform shown as `+transform` suffix: `FWString+transform`
- Multiple non-defaults: `FWInt(pad='0', default=0)+transform`

### Implementation

- `Base.show(io::IO, s::FixedWidthSchema)` — compact single-line
- `Base.show(io::IO, ::MIME"text/plain", s::FixedWidthSchema)` — multi-line table
- `_descriptor_string(desc)` — helper to format a descriptor with its non-default parameters
- Column widths auto-adjust to longest field name and type string

---

## Feature 6: Multi-Record Types

New `MultiRecordSchema` for files with header/detail/trailer record types.

### API

```julia
ms = MultiRecordSchema(
    1:1,                    # discriminator byte range
    "H" => header_schema,  # label defaults to :H
    "D" => detail_schema,
    "T" => trailer_schema,
)

# parse_file returns Dict{Symbol, StructArray}
result = parse_file("data.dat", ms)
result[:H]  # StructArray of header records
result[:D]  # StructArray of detail records
```

### Struct

```julia
struct MultiRecordSchema
    discriminator::UnitRange{Int}
    schemas::Vector{Tuple{String, Symbol, FixedWidthSchema}}
    record_width::Int
end
```

### Construction

```julia
function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{String, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
```

- Labels derived from discriminator values: `"H"` → `:H`
- All schemas must have compatible record widths
- `record_width` keyword overrides if needed (schemas may be narrower than the actual line)

### Parsing Strategy

1. Open `MmapSource` with the maximum schema `record_width`
2. Apply `skip_header`, `skip_footer`, `comment` filtering
3. First pass: read discriminator bytes for every valid record, classify into groups (build `Dict{Symbol, Vector{Int}}` of record indices per type)
4. Unknown discriminator → `ArgumentError` with line number and raw value
5. Second pass: for each group, call existing `_parse_columnar_indexed` with the group's schema and indices
6. Return `Dict{Symbol, StructArray}`

### eachrecord

`eachrecord(path, ms)` yields `NamedTuple`s. Each tuple includes a `:_type::Symbol` field identifying which schema matched, plus the fields from that schema. Since different schemas have different fields, the tuple type varies per record — the iterator's `eltype` is `NamedTuple`.

### Keyword Support

- `skip_header`, `skip_footer`, `comment` — applied before classification
- `on_error` — applies uniformly to all schemas
- `select`/`exclude` — not supported on MultiRecordSchema (apply to individual schemas before constructing the MultiRecordSchema)
- `ntasks` — applies to each group's columnar parse independently

### Validation

- Empty discriminator range → `ArgumentError`
- Duplicate discriminator values → `ArgumentError`
- Schema record_width inconsistencies → `ArgumentError` (unless `record_width` keyword overrides)
- Empty pairs → `ArgumentError`

---

## Feature 7: @generated Specialization

### 7a: Polish Existing @fixedwidth Path

Update `_parse_columnar_generated` to handle:

- `FWBool` — emit `parse_field(FWBool("Y","N"), buf, pos, w)` with baked values
- Custom pad on FWInt/FWFloat — emit pad replacement + parse
- Defaults — emit blank detection + default return when `:default` mode
- Transforms — emit `desc.transform(parse_field(...))` when transform is set
- Parallel support — partition the generated loop and spawn tasks
- Filtered support — use indices vector in the generated loop

### 7b: Extend to Runtime Schemas

Encode a schema's structure into a type parameter to trigger `@generated` specialization for runtime schemas:

```julia
struct SchemaSpec{Fields} end
```

`Fields` is a tuple encoding each field's `(offset, width, type_tag, pad_byte)`. For example:

```julia
SchemaSpec{((1, 2, :string, 0x20), (3, 4, :int, 0x20), (7, 3, :skip, 0x20))}
```

### Conversion

```julia
function schema_spec(s::FixedWidthSchema) → SchemaSpec{...}
```

Converts a schema to a `SchemaSpec` type. Only works for schemas with "simple" descriptors — no closures in transforms. Returns `nothing` if the schema can't be encoded (falls back to runtime path).

### Type Tags

| Descriptor | Tag |
|-----------|-----|
| FWString | `:string` |
| FWInt | `:int` |
| FWFloat | `:float` |
| FWBool | `:bool` |
| FWDate | `:date` |
| FWFixedPoint | `:fixedpoint` |
| FWSkip | `:skip` |

Additional parameters (date format, fixed-point decimals, bool true/false values, default values) are encoded as extra tuple elements.

### parse_file Integration

When `parse_file` is called with a runtime schema and `ntasks <= 1` and no filtering:

1. Try `schema_spec(schema)` — if it returns a `SchemaSpec`, call the `@generated` path
2. If it returns `nothing` (schema has closures), fall back to runtime path

### Performance Expectation

The generated path eliminates per-field dynamic dispatch and enables inlining of `parse_field`. Expected 2-3x speedup for schemas with many fields. The biggest win is for string fields where `_inline_from_buf` is called directly.

---

## Error Handling Summary

| Scenario | Behavior |
|----------|----------|
| FWBool mismatch | ArgumentError (strict/default), missing (lenient) |
| FWBool("","N") empty true_val | ArgumentError at construction |
| FWInt(pad='*') with bad data | ArgumentError as today |
| Default value wrong type | ArgumentError at construction |
| Transform throws | ParseError (strict/default), missing (lenient) |
| Unknown discriminator value | ArgumentError with line number and raw value |
| Mismatched record_width in MultiRecordSchema | ArgumentError at construction |
| Schema can't be encoded as SchemaSpec | Silent fallback to runtime path |

## Testing

- **FWBool:** Y/N, T/F, custom pairs, whitespace, mismatch, lenient, @fixedwidth macro, _parse_type_string
- **Custom pad:** zero-padded int, asterisk-padded float, mixed with spaces
- **Defaults:** :default mode, all-blank returns default, bad data throws, no-default blanks throw, interaction with lenient
- **Transforms:** identity, uppercase, type-changing, with defaults, with lenient, error in transform
- **Schema show:** compact and multi-line, all types, non-default params, transform suffix
- **MultiRecordSchema:** basic H/D/T, unknown discriminator, skip_header, eachrecord, empty groups, record_width override
- **@generated:** benchmark generated vs runtime, all descriptor types, parallel generated, filtered generated, runtime schema spec encoding, fallback for closures
