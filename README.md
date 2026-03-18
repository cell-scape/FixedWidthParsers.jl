# FixedWidthParsers.jl

Fixed-width file parser for Julia.

## Features

- **Runtime and compile-time schemas** — `FixedWidthSchema` or `@fixedwidth struct`
- **Columnar output** — returns `StructArray` with zero-copy InlineStrings
- **Row-oriented output** — `Vector{NamedTuple}` when `columnar=false`
- **Lazy iteration** — `eachrecord` with Tables.jl interface
- **Parallel parsing** — `ntasks` keyword for multi-threaded columnar fill
- **Column selection** — `select` and `exclude` keywords to parse a subset of fields
- **Byte-range schemas** — specify fields by `start:end` byte positions with auto gap-fill
- **Schema file loading** — `load_schema` reads schemas from CSV, TOML, and JSON files
- **Multi-record files** — `MultiRecordSchema` parses files with mixed record types identified by a discriminator field
- **Bundled schemas** — Pre-built schemas for SSIM schedules, aircraft, airport, MCT, and more
- **Record skipping** — `skip_header`, `skip_footer`, `comment` keywords
- **Error modes** — strict (throw `ParseError`) or lenient (return `missing`)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/cell-scape/FixedWidthParsers.jl")
```

## Quick Start

### Runtime schema

```julia
using FixedWidthParsers

schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
)

sa = parse_file("flights.dat", schema)
sa.carrier  # Vector{String7}
sa.fnum     # Vector{Int}
```

### Compile-time schema

```julia
@fixedwidth struct Flight
    carrier::String = 2
    fnum::Int       = 4
    origin::String  = 3
end

sa = parse_file("flights.dat", Flight)
```

## Skipping Headers, Footers, and Comments

```julia
# Skip 2 header lines and 1 footer line
sa = parse_file("data.dat", schema; skip_header=2, skip_footer=1)

# Skip lines whose first byte is '#'
sa = parse_file("data.dat", schema; comment=UInt8('#'))

# Combine all three
sa = parse_file("data.dat", schema;
    skip_header=1, skip_footer=1, comment=UInt8('#'))
```

## Column Selection

```julia
# Parse only specific columns
sa = parse_file("flights.dat", schema; select=[:carrier, :origin])

# Exclude columns you don't need
sa = parse_file("flights.dat", schema; exclude=[:fnum])

# Column selection also works with the lazy iterator
for rec in eachrecord("flights.dat", schema; select=[:carrier, :origin])
    println(rec.carrier)
end
```

`select` and `exclude` are mutually exclusive — use one or the other, not both.

## Byte-Range Schemas

```julia
# Range-based: specify start:end for each field
schema = FixedWidthSchema(
    :carrier => (1:2, FWString()),
    :fnum    => (3:6, FWInt()),
    :origin  => (10:12, FWString()),  # gap at 7-9 auto-fills with FWSkip
)

# Start+width: specify (start, width, descriptor)
schema = FixedWidthSchema(
    :carrier => (1, 2, FWString()),
    :fnum    => (3, 4, FWInt()),
)
```

## Loading Schemas from Files

```julia
# Load from CSV (name, start, end, type columns)
schema = load_schema("flights.csv")

# Load from TOML
schema = load_schema("flights.toml")

# Load from JSON (requires `using JSON3`)
using JSON3
schema = load_schema("flights.json")
```

## Multi-Record Parsing

Parse files where each line can be a different record type, identified by a discriminator field:

```julia
header = FixedWidthSchema(:rec_type => (1, FWString()), :title => (9, FWString()))
detail = FixedWidthSchema(:rec_type => (1, FWString()), :code  => (3, FWString()), :value => (6, FWInt()))

ms = MultiRecordSchema(1:1, "H" => header, "D" => detail)

result = parse_file("mixed.dat", ms)
result[:H].title   # Vector of header titles
result[:D].value   # Vector of detail values
```

Discriminator keys can be `String`, `Char`, `Int`, or mixed:

```julia
ms = MultiRecordSchema(1:1, 'H' => header, 'D' => detail)
```

Lazy iteration works too — each record includes a `:_type` field:

```julia
for rec in eachrecord("mixed.dat", ms)
    if rec._type === :H
        println("Header: ", rec.title)
    end
end
```

Load multi-record schemas from multiple CSV files with explicit discriminator keys:

```julia
ms = load_schema(
    '1' => "type1_schema.csv",
    '2' => "type2_schema.csv";
    discriminator=1:1,
    record_width=200,
)
```

## Bundled Schemas

Pre-built schemas for common aviation fixed-width formats:

```julia
using FixedWidthParsers

# Parse a full SSIM schedule file (5 record types, 200-byte lines)
result = parse_file("schedule.ssim", SSIM_SCHEMA; on_error=:lenient)
result[:type_3]  # flight leg records

# Parse reference data files
aircraft = parse_file("aircraft.dat", AIRCRAFT_SCHEMA)
airports = parse_file("airports.dat", AIRPORT_SCHEMA)
```

| Schema | Type | Description |
|--------|------|-------------|
| `SSIM_SCHEMA` | `MultiRecordSchema` | SSIM schedules (types 1–5, discriminator at byte 1) |
| `AIRCRAFT_SCHEMA` | `FixedWidthSchema` | IATA aircraft equipment reference |
| `AIRPORT_SCHEMA` | `FixedWidthSchema` | IATA airport/timezone reference |
| `MCT_SCHEMA` | `FixedWidthSchema` | Minimum Connecting Time (byte order) |
| `MCT_PRIORITY_SCHEMA` | `FixedWidthSchema` | MCT (priority order) |
| `REGIONAL_SCHEMA` | `FixedWidthSchema` | Region/airport/city mapping |
| `SEATS_SCHEMA` | `FixedWidthSchema` | Seat configuration data |

## Parallel Parsing

```julia
# Parse with 4 tasks (columnar mode only)
sa = parse_file("large.dat", schema; ntasks=4)
```

## Lazy Iteration

```julia
for rec in eachrecord("flights.dat", schema)
    println(rec.carrier, " ", rec.fnum)
end
```

`eachrecord` supports Tables.jl, so you can pipe directly into DataFrames or other sinks.

## Field Types

| Type | Julia Type | Description |
|------|-----------|-------------|
| `FWString()` | `String` / `InlineString` | Fixed-width string, right-padded |
| `FWInt()` | `Int` | Integer |
| `FWFloat()` | `Float64` | Floating-point |
| `FWDate(fmt)` | `Date` | Date with format string (default `"yyyymmdd"`) |
| `FWTime(fmt)` | `Time` | Time with format string (default `"HHMM"`) |
| `FWDateTime(fmt)` | `DateTime` | DateTime with format string |
| `FWFixedPoint(n)` | `Float64` | Implied-decimal fixed point |
| `FWBool(trueval)` | `Bool` | Matches a specific true value |
| `FWCustom(f)` | any | Custom parse function |
| `FWSkip()` | — | Skip field (excluded from output) |

## Documentation

Build the full API reference locally:

```bash
julia --project=docs docs/make.jl
open docs/build/index.html
```


