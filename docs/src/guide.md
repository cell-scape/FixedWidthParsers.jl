# User Guide

This page is the consolidated feature reference. If you're new, start with
the [Quick Start tutorial](tutorials/quickstart.md); if you want a specific
function, [API Reference](api.md) is your friend.

## Schemas

A `FixedWidthSchema` describes the byte layout of a fixed-width record.
Three construction forms are supported — choose whichever matches the spec
you're working from.

### Width mode

The original form. Fields are contiguous; widths must sum to the record
width (plus any newline bytes the file actually uses).

```julia
schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
)
# record_width(schema) == 9
```

### Byte-range mode

When the spec is given as byte positions, use `start:end`. Gaps are
auto-filled with `FWSkip`; you can supply fields out of order.

```julia
schema = FixedWidthSchema(
    :carrier => (1:2,   FWString()),
    :fnum    => (3:6,   FWInt()),
    :origin  => (10:12, FWString()),   # bytes 7-9 auto-skip
    ;
    record_width = 200,                # trailing bytes also skipped
)
```

### `(start, width, descriptor)` mode

A hybrid — handy when the spec gives you both positions and widths.

```julia
schema = FixedWidthSchema(
    :carrier => (1, 2, FWString()),
    :fnum    => (3, 4, FWInt()),
)
```

!!! warning
    Don't mix the three forms in one call. Pick one.

### Compile-time schemas via `@fixedwidth`

If you know the schema at code-write time, the macro compiles a struct and
emits a specialized parse loop that's ~1.6× faster single-threaded than the
runtime path:

```julia
using FixedWidthParsers: Skip

@fixedwidth struct Flight
    carrier::String = 2
    fnum::Int       = 4
    _pad::Skip      = 1
    origin::String  = 3
end

parse_file("flights.dat", Flight)          # dispatches to the generated path
schema(Flight)                              # get the underlying FixedWidthSchema
```

## Field descriptors

| Descriptor        | Parses          | Notes                                                   |
|-------------------|-----------------|---------------------------------------------------------|
| `FWString`        | `InlineString`  | Trailing pad stripped. `pad`, `default`, `transform`.   |
| `FWInt`           | `Int`           | Signed. `pad`, `default`, `transform`.                  |
| `FWFloat`         | `Float64`       | Decimal notation.                                       |
| `FWFixedPoint(n)` | `Float64`       | Implied-decimal: `"12345"` with `n=2` → `123.45`.       |
| `FWBool`          | `Bool`          | Configurable `true_val` / `false_val` (default `"Y"` / `"N"`). |
| `FWDate(fmt)`     | `Date`          | Fast path for several formats — see below.              |
| `FWTime(fmt)`     | `Time`          | Fast path for `HHMM`, `HH:MM`, etc.                     |
| `FWDateTime(fmt)` | `DateTime`      | Fast path for `yyyymmddHHMM`, `yyyymmddHHMMSS`.         |
| `FWCustom(T, fn)` | `T`             | User-supplied parser; `raw=true` for byte-level.        |
| `FWSkip`          | (nothing)       | Byte range ignored; excluded from output.               |

### Fast-path date/time formats

These formats dispatch to byte-level parsers that skip the `DateFormat`
interpreter entirely — ~15× faster on date-heavy schemas:

| Format           | Example              |
|------------------|----------------------|
| `yyyymmdd`       | `20260401`           |
| `yyyy-mm-dd`     | `2026-04-01`         |
| `dduuuyy`        | `10Jan26`            |
| `HHMM`           | `0930`               |
| `HHMMSS`         | `093045`             |
| `HH:MM`          | `09:30`              |
| `HH:MM:SS`       | `09:30:45`           |
| `yyyymmddHHMM`   | `202603171430`       |
| `yyyymmddHHMMSS` | `20260317143045`     |

Any other format string still works — it just goes through `Dates.DateFormat`
at the normal Dates.jl speed.

## Parsing

### From a file path (mmap'd)

```julia
sa = parse_file(path, schema)   # StructArray (columnar, default)
rows = parse_file(path, schema; columnar = false)   # Vector{NamedTuple}
```

### From an `IO` stream or in-memory buffer

```julia
parse_file(io, schema; kwargs...)
parse_string(str, schema; kwargs...)
parse_bytes(bytes, schema; kwargs...)
```

All three accept the same kwargs as the path-based `parse_file`.

### Lazy iteration

`eachrecord` yields one record at a time. Memory use is independent of file
size, and the iterator implements the `Tables.jl` row interface so it composes
with `DataFrames`, CSV writers, etc.:

```julia
for rec in eachrecord(path, schema)
    # rec is a NamedTuple
    rec.carrier == "UA" && println(rec.fnum)
end
```

## Keyword arguments

All parsing entry points accept:

| kwarg             | Type                               | Effect                                                   |
|-------------------|------------------------------------|----------------------------------------------------------|
| `columnar`        | `Bool` (default `true`)            | `false` returns `Vector{NamedTuple}`.                    |
| `on_error`        | `Symbol` (default `:strict`)       | `:strict`, `:lenient`, or `:default`.                    |
| `ntasks`          | `Int` (default `1`)                | Parallel parse tasks per chunk (columnar only).          |
| `skip_header`     | `Int` (default `0`)                | Drop the first N records.                                |
| `skip_footer`     | `Int` (default `0`)                | Drop the last N records.                                 |
| `comment`         | `Union{UInt8, Nothing}`            | Drop records whose first byte matches.                   |
| `select`          | `Union{AbstractVector{Symbol}, Nothing}` | Keep only these columns; mutually exclusive with `exclude`. |
| `exclude`         | `Union{AbstractVector{Symbol}, Nothing}` | Drop these columns.                                  |

## Error handling

`:strict` (default) throws `ParseError` on the first bad field. The error
includes the line number, column range, raw bytes, expected type, and the
underlying `Exception`.

`:lenient` catches parse errors, returns `missing` for the affected field,
and emits a `@warn`. Columns affected by any lenient failure have eltype
`Union{T, Missing}`.

`:default` substitutes the descriptor's `default` value when the field is
entirely pad characters. Blank fields without a configured default still
throw.

```julia
FWInt(; default = 0)
FWString(; default = "")
FWDate("yyyymmdd"; default = Date(1900, 1, 1))
```

## Transforms

Any descriptor accepts a post-parse `transform = fn` that runs on the parsed
value:

```julia
# Convert to uppercase
FWString(; transform = uppercase)

# Multiply by 100 (cents → pennies)
FWInt(; transform = x -> x * 100)

# Apply a timezone
FWDateTime("yyyymmddHHMM"; transform = dt -> ZonedDateTime(dt, tz"UTC"))
```

When a transform is set, the column eltype widens to `Any` (the parser
can't predict the return type). For type-stable output, annotate:

```julia
FWInt(; transform = x -> x * 100 |> Float64)    # still Any column
# Prefer: keep the schema Int, do the conversion after parsing
```

## Multi-record files

Some formats pack multiple record types in one file, distinguished by a
discriminator byte range. `MultiRecordSchema` handles this:

```julia
hdr = FixedWidthSchema(:rec => (1, FWString()), :title => (9, FWString()))
det = FixedWidthSchema(:rec => (1, FWString()), :code  => (3, FWString()),
                                                :value => (6, FWInt()))
ms = MultiRecordSchema(1:1, "H" => hdr, "D" => det)

# parse_file returns a Dict{Symbol, StructArray}
result = parse_file("mixed.dat", ms)
result[:H].title
result[:D].value

# eachrecord yields a _type field per row
for rec in eachrecord("mixed.dat", ms)
    rec._type === :H ? println("hdr: ", rec.title) : println("det: ", rec.value)
end
```

Keys can be `String`, `Char`, or `Int`. See the multi-record section in the
[Handling Real Data](tutorials/real_data.md#_9_-multi-record-files) tutorial
for a walkthrough.

### Bundled schemas

Several common formats ship pre-built:

| Schema                | Type                 | Description                                  |
|-----------------------|----------------------|----------------------------------------------|
| `SSIM_SCHEMA`         | `MultiRecordSchema`  | SSIM airline schedules, 5 record types       |
| `AIRCRAFT_SCHEMA`     | `FixedWidthSchema`   | IATA aircraft equipment reference            |
| `AIRPORT_SCHEMA`      | `FixedWidthSchema`   | IATA airport / timezone reference            |
| `MCT_SCHEMA`          | `FixedWidthSchema`   | Minimum Connecting Time (byte order)         |
| `MCT_PRIORITY_SCHEMA` | `FixedWidthSchema`   | Minimum Connecting Time (priority order)     |
| `REGIONAL_SCHEMA`     | `FixedWidthSchema`   | Region / airport / city mapping              |
| `SEATS_SCHEMA`        | `FixedWidthSchema`   | Seat configuration data                      |

## Loading schemas from files

```julia
# CSV: columns name, start, end, type (plus optional format)
#   carrier,1,2,String
#   fnum,3,6,Int
#   dep_date,7,14,Date,yyyymmdd
schema = load_schema("flights.csv")

# TOML (array-of-tables format)
schema = load_schema("flights.toml")

# JSON — weakdep, requires `using JSON3`
using JSON3
schema = load_schema("flights.json")
```

Multi-record schemas load from multiple files with explicit discriminator keys:

```julia
ms = load_schema(
    '1' => "type1_schema.csv",
    '2' => "type2_schema.csv",
    '3' => "type3_schema.csv";
    discriminator = 1:1,
    record_width  = 200,
)
```

## DuckDB integration

See the [DuckDB Extension](duckdb.md) page and the
[Streaming to DuckDB](tutorials/duckdb.md) tutorial.

## Performance

See the [Performance](performance.md) page for end-to-end throughput numbers.
Short version:

- Columnar single-threaded: **~22 M rec/s** on a narrow schema.
- Columnar 8-threaded: **~80 M rec/s**.
- Row-oriented: ~1.05× slower than columnar (same underlying columnar parse,
  then transposed).
- Date-heavy schemas with fast-path formats: ~15× faster than without.

## Interop

### Tables.jl

Both `StructArray` (from `parse_file`) and `RecordIterator` (from `eachrecord`)
implement `Tables.jl`. They drop straight into DataFrames, CSV writers, Arrow,
Parquet, DuckDB, Stipple, etc.:

```julia
using DataFrames
df = DataFrame(parse_file(path, schema))

using CSV
CSV.write("out.csv", parse_file(path, schema))
```

### StructArrays.jl

`parse_file` returns a `StructArray` directly — you can access columns as
`sa.carrier` and rows as `sa[i]` (returns a concrete `NamedTuple`).

### InlineStrings.jl

String fields up to 31 bytes use `InlineString` for zero-GC-pressure storage.
Columns are typed as the smallest variant that fits (`String1`, `String3`,
`String7`, `String15`, `String31`, or heap-allocated `String` for longer).
