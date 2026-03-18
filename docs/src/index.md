# FixedWidthParsers.jl

Fixed-width file parser for Julia. Supports runtime and compile-time schemas, columnar and row-oriented output, lazy iteration, parallel parsing, and the Tables.jl interface.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/cell-scape/FixedWidthParsers.jl")
```

## Quick Example

```julia
using FixedWidthParsers

# Define a schema
schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
)

# Parse a file into a StructArray
sa = parse_file("flights.dat", schema)
sa.carrier  # Vector of airline codes
sa.fnum     # Vector of flight numbers

# Or use a compile-time schema
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

The same keywords work with the lazy iterator:

```julia
for rec in eachrecord("data.dat", schema; skip_header=1, comment=UInt8('#'))
    println(rec.carrier)
end
```

## Column Selection

```julia
# Parse only specific columns
sa = parse_file("data.dat", schema; select=[:carrier, :origin])

# Exclude columns you don't need
sa = parse_file("data.dat", schema; exclude=[:fnum])

# Column selection also works with the lazy iterator
for rec in eachrecord("data.dat", schema; select=[:carrier, :origin])
    println(rec.carrier)
end
```

`select` and `exclude` are mutually exclusive — use one or the other, not both.

## Byte-Range Schemas

You can specify explicit byte positions instead of contiguous widths:

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

Fields can be specified in any order — they are sorted by start byte automatically. Gaps between fields are filled with `FWSkip`.

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

Discriminator keys can be `String`, `Char`, `Int`, or mixed types. Lazy iteration works too — each record includes a `_type` field identifying the matched schema:

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
```

Available bundled schemas: [`SSIM_SCHEMA`](@ref), [`AIRCRAFT_SCHEMA`](@ref), [`AIRPORT_SCHEMA`](@ref), [`MCT_SCHEMA`](@ref), [`MCT_PRIORITY_SCHEMA`](@ref), [`REGIONAL_SCHEMA`](@ref), [`SEATS_SCHEMA`](@ref).

See the [API Reference](@ref) for full documentation.

