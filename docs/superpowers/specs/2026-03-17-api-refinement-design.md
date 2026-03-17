# FixedWidthParsers.jl API Refinement Design

**Date:** 2026-03-17
**Status:** Approved
**Goal:** Make the library more user-friendly, especially for multi-record files like OAG SSIM7/SSIM8.

## Problem Statement

The current API has several friction points that make it difficult to get started:

1. `MultiRecordSchema` discriminator keys are String-only — users can't use `Char` or `Int` literals even when that's the natural representation (e.g., single-byte record type indicators).
2. Building a multi-record schema requires manually loading each sub-schema individually and wiring them together — tedious and error-prone.
3. No `FWTime` or `FWDateTime` descriptors — only `FWDate` exists, with no way to parse time-only or datetime fields.
4. No generic custom field descriptor for user-defined parsing logic.
5. Schema files (CSV/TOML/JSON) have no way to specify format strings for Date/Time/DateTime fields.
6. `FixedWidthSchema` requires `Symbol` field names — can't pass `String` keys without manual conversion.

## Design

### Section 1: Flexible Discriminator Key Types in MultiRecordSchema

The `MultiRecordSchema` constructor accepts `Char`, `Int`, and `String` keys. The key type drives how discriminator bytes are compared and how output labels are derived.

#### Constructor Signatures

```julia
# Char keys — single-byte discriminator, compared as raw byte
MultiRecordSchema(1:1, 'H' => header_schema, 'D' => detail_schema)

# Int keys — discriminator bytes parsed via tryparse(Int, ...)
MultiRecordSchema(1:2, 1 => type1_schema, 2 => type2_schema)

# String keys — compared as string (current behavior)
MultiRecordSchema(1:3, "HDR" => header_schema, "DTL" => detail_schema)

# Convenience: single Int position instead of range
MultiRecordSchema(1, 'H' => header_schema, 'D' => detail_schema)  # equivalent to 1:1
```

#### Output Label Derivation

| Key type | Example key | Output label |
|----------|------------|--------------|
| `Char`   | `'H'`     | `:H`         |
| `Int`    | `1`        | `:type_1`    |
| `String` | `"HDR"`    | `:HDR`       |

#### Internal Representation

Internal storage stays as `Vector{Tuple{String, Symbol, FixedWidthSchema}}`. Discriminator values are normalized to bytes at construction time for efficient comparison. The original key is preserved for error messages.

#### Validation

- All keys must be the same type (no mixing `Char` with `Int`).
- For `Char` keys, the discriminator range length must be exactly 1.
- No duplicate discriminator values.

### Section 2: Ergonomic `load_schema` for Multi-Record Files

`load_schema` becomes the single entry point for both single and multi-record schema loading. One file yields a `FixedWidthSchema`. Multiple files yield a `MultiRecordSchema`.

#### Single Schema (Unchanged)

```julia
schema = load_schema("flights.csv")
schema = load_schema("flights.csv"; record_width=200)
```

#### Multi-Record — Files Only, Everything Inferred

```julia
ms = load_schema("header.csv", "detail.csv", "trailer.csv")
# discriminator: 1:1 (default)
# labels: :header, :detail, :trailer (from filenames sans extension)
# record_width: max of all sub-schemas
```

#### Multi-Record — Explicit Discriminator Values via Pair Keys

```julia
ms = load_schema('H' => "header.csv", 'D' => "detail.csv")
# discriminator: 1:1 (default), labels: :H, :D

ms = load_schema("HDR" => "header.csv", "DTL" => "detail.csv"; discriminator=1:3)
# discriminator: 1:3, labels: :HDR, :DTL
```

#### Multi-Record — Bare Files with Keyword Overrides

```julia
ms = load_schema("header.csv", "detail.csv";
    discriminator=1:2,
    record_width=200,
)
# labels: :header, :detail (from filenames)
```

#### Keyword Arguments (Multi-Record Only)

| Keyword | Default | Description |
|---------|---------|-------------|
| `discriminator` | `1:1` | Byte range (or single `Int` position) for record type indicator |
| `record_width` | `nothing` (inferred from max sub-schema) | Override total record width |

#### Filename-to-Label Logic

1. Take `basename` without extension (e.g., `"header.csv"` → `"header"`)
2. Convert to `Symbol` (e.g., `:header`)
3. If filenames collide after stripping extensions, throw an `ArgumentError` asking the user to use explicit Pair keys instead.

#### Dispatch Rule

- If all positional args are `AbstractString` (not `Pair`): count them. One = single schema. Two or more = multi-record with filenames as labels.
- If any positional arg is a `Pair`: it's multi-record with explicit discriminator values.

### Section 3: New Field Descriptors — FWTime, FWDateTime, FWCustom

#### FWTime

Parses `Dates.Time` with a format string:

```julia
FWTime("HHmm")
FWTime("HH:MM:SS")
FWTime("HHmmss"; default=Time(0,0,0), transform=identity)
```

Structure mirrors `FWDate`: stores `Dates.DateFormat` + `format_string` + `default` + `transform`. `parse_field` reads bytes as a string and calls `Dates.Time(str, format)`.

#### FWDateTime

Parses `Dates.DateTime` with a format string:

```julia
FWDateTime("ddMMMyyHHmm")
FWDateTime("yyyy-mm-ddTHH:MM:SS"; default=DateTime(0))
```

Same pattern as `FWDate`/`FWTime`.

#### FWCustom

Generic field with a user-provided parse function. Two modes:

```julia
# String mode (default): library extracts/trims field, hands you a String
FWCustom(String, s -> parse(IPv4, s))
FWCustom(Int, s -> length(s))

# Byte mode: raw buffer access for performance
FWCustom(Float64, (buf, pos, len) -> my_fast_parser(buf, pos, len); raw=true)
```

Structure:

```julia
struct FWCustom
    return_type::Type           # Julia type of the parsed value
    parse_fn::Function          # user's function
    raw::Bool                   # false = string mode, true = byte mode
    default::Union{Any,Nothing}
    transform::Union{Function,Nothing}
end
```

`parse_field` behavior:
- `raw=false`: extract bytes as `String`, call `parse_fn(str)`
- `raw=true`: call `parse_fn(buf, pos, len)` directly

`FWCustom` is not expressible from schema files (requires a function) — code-only.

### Section 4: Optional Format Column in Schema Files

An optional `format` column in CSV/TOML/JSON schema files. Gracefully ignored when absent or empty.

#### CSV Example — With Format

```
name,start,end,type,format
rec_type,1,1,String,
dep_date,2,8,Date,ddMMMyy
dep_time,10,13,Time,HHmm
carrier,14,15,String,
amount,16,25,FixedPoint(2),
```

#### CSV Example — Without Format (Unchanged)

```
name,start,end,type
rec_type,1,1,String
carrier,2,3,String
```

#### Behavior

- Format column header absent → works exactly as today.
- Format column header present but row value empty → uses the type's default format (e.g., `"yyyymmdd"` for `Date`, `"HH:MM:SS"` for `Time`, `"yyyy-mm-ddTHH:MM:SS"` for `DateTime`).
- If both the type string contains a format (e.g., `Date(ddMMMyy)`) **and** the format column has a value → format column wins.
- Format provided for a type that doesn't use formats (like `String`, `Int`) → silently ignored.

#### Implementation

A new internal function `_parse_type_string(type_str, format_str)`:
1. If `format_str` is non-empty and type is `Date`/`Time`/`DateTime` → use `format_str` as the format.
2. Otherwise fall through to existing `_parse_type_string(type_str)` logic.

TOML and JSON follow the same approach — optional `"format"` key per field entry.

### Section 5: Minor Ergonomic Improvements

#### Accept String Field Names in FixedWidthSchema

Accept `Pair{<:Union{Symbol, AbstractString}}` and auto-convert strings to symbols:

```julia
# Both work:
FixedWidthSchema(:carrier => (2, FWString()))      # current
FixedWidthSchema("carrier" => (2, FWString()))      # new
```

#### Accept Int for Discriminator Position

Bare `Int` as shorthand for a single-byte range:

```julia
MultiRecordSchema(1, 'H' => hschema)    # equivalent to 1:1
```

## Backward Compatibility

All changes are additive. Existing API signatures continue to work without modification:

- `MultiRecordSchema(1:1, "H" => schema)` — still works (String keys)
- `load_schema("file.csv")` — still works (single file)
- `FixedWidthSchema(:name => (2, FWString()))` — still works (Symbol keys)
- Schema files without `format` column — still work

## New Exports

- `FWTime`
- `FWDateTime`
- `FWCustom`

## Out of Scope

- Schema file references to custom parse functions (requires code, not declarative)
- Automatic record width inference by reading the data file (could be a future enhancement)
- Changes to `@fixedwidth` macro (already ergonomic for its use case)
