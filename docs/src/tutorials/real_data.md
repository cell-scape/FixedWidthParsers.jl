# Tutorial: Handling Real Data

Production fixed-width files are rarely as clean as the tutorial examples.
They have header rows, comments, blank fields, mixed record types, and the
occasional corrupt line. This tutorial shows how FixedWidthParsers.jl handles
each of those cases.

You should be comfortable with [Quick Start](quickstart.md) before reading this.

## 1. Skip header and footer rows

Many files start with metadata or column descriptors and end with a summary
trailer:

```
DATE 20260401                              ← header, not data
CARRIER FLIGHT ORG DEST PAX                ← column names
UA1234ORDSFO  150                          ← data starts here
DL 567LAXJFK  220
AA 999SFOORD  187
SUMMARY 3 records                          ← footer, not data
```

Pass `skip_header` and `skip_footer`:

```julia
using FixedWidthParsers

schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
    :dest    => (3, FWString()),
    :pax     => (4, FWInt()),
)

sa = parse_file("flights.dat", schema;
                skip_header = 2, skip_footer = 1)
```

!!! note
    Header and footer rows **must** be the same fixed width as data rows.
    FixedWidthParsers strides through the file in `record_width + newline_width`
    byte steps; short rows would desynchronize the scan.

## 2. Skip comment lines

When the format allows comments, they usually start with a marker byte like
`#` or `*`. Use `comment` with a single `UInt8`:

```julia
sa = parse_file("flights.dat", schema; comment = UInt8('#'))
```

Comment rows also need to be full-width. The parser checks the first byte of
each slot and drops the whole row if it matches.

You can combine all three filters:

```julia
sa = parse_file("flights.dat", schema;
                skip_header = 1, skip_footer = 1, comment = UInt8('#'))
```

## 3. Handle parse errors (three modes)

Fixed-width data often includes malformed values — a letter where a number
should be, an out-of-range date, etc. Control behavior with `on_error`:

### `:strict` (default) — fail fast with a rich error

```julia
try
    sa = parse_file("dirty.dat", schema)
catch e
    # e is a ParseError with the exact line, column range, raw bytes, and
    # expected type
    println("line=", e.line, " cols=", e.columns, " got=", e.raw_bytes)
end
```

Strict mode is right when bad data should halt the pipeline. The error points
at the exact byte range that failed so you can fix the source or patch the
schema.

### `:lenient` — replace unparseable fields with `missing`

```julia
sa = parse_file("dirty.dat", schema; on_error = :lenient)

# Affected columns are Vector{Union{T, Missing}}
eltype(sa.fnum)           # Union{Int, Missing}
count(ismissing, sa.fnum) # number of failed rows in this column

# Filter to just the good rows
clean = filter(r -> all(!ismissing, r), sa)
```

Lenient mode is right for exploration and ingestion of third-party data where
you'd rather have some data than none.

### `:default` — substitute a value for blank fields

When fields are left blank (all-pad characters) rather than being malformed,
use `:default` with pre-configured defaults:

```julia
schema = FixedWidthSchema(
    :carrier => (2, FWString(; default = "??")),
    :fnum    => (4, FWInt(; default = 0)),
    :origin  => (3, FWString()),                   # no default → still errors
)

sa = parse_file("sparse.dat", schema; on_error = :default)
```

Blank fields with no configured default will still throw `ParseError`.

## 4. Custom padding

Non-space padding (like leading zeros in numeric fields) needs an explicit
`pad` kwarg:

```julia
# Field layout: "0042" → 42, "  12" → 12
fw_int_zero = FWInt(; pad = '0')
fw_int_spc  = FWInt(; pad = ' ')   # the default

# String padded with a specific character
fw_str_star = FWString(; pad = '*')   # "UA***" → "UA"
```

## 5. Date and time formats

Nine common formats dispatch to byte-level fast parsers (no `DateFormat`
overhead — ~15× faster on date-heavy schemas):

```julia
FWDate("yyyymmdd")          # 20260401 → 2026-04-01
FWDate("yyyy-mm-dd")        # 2026-04-01
FWDate("dduuuyy")           # 10Jan26   → 0026-01-10  (literal 2-digit year, matching Dates.jl)

FWTime("HHMM")              # 0930    → 09:30
FWTime("HHMMSS")            # 093045  → 09:30:45
FWTime("HH:MM")             # 09:30
FWTime("HH:MM:SS")          # 09:30:45

FWDateTime("yyyymmddHHMM")
FWDateTime("yyyymmddHHMMSS")
```

Any other format string still works — it just goes through `Dates.DateFormat`
at normal speed.

!!! note
    Julia's `DateFormat` convention differs from many spec sheets:
    lowercase `m` is **month**, uppercase `M` is **minute**. If you're
    writing a format like "HHMM" (hour+minute), use uppercase `M`.

## 6. Column selection

When you only need a subset of fields, `select` or `exclude` parse the wanted
columns and treat the rest as skip fields (no allocation, no parsing work):

```julia
# Only carrier and origin
sa = parse_file("flights.dat", schema; select = [:carrier, :origin])

# Everything except pax
sa = parse_file("flights.dat", schema; exclude = [:pax])
```

`select` and `exclude` are mutually exclusive. The options flow through to
`eachrecord` too.

## 7. Byte-range schemas for sparse fields

If a format spec gives you byte positions instead of widths — common when
a format covers 200 bytes but you only care about a few fields — use
range-based construction:

```julia
schema = FixedWidthSchema(
    :carrier    => (1:2,   FWString()),
    :flight_num => (3:6,   FWInt()),
    :origin     => (10:12, FWString()),   # bytes 7-9 become an auto FWSkip
    :dest       => (13:15, FWString()),
    ;
    record_width = 200,                   # pad the rest with FWSkip
)
```

Gaps between fields are filled with `FWSkip` automatically; the trailing
`record_width` keyword extends the schema to the full line length.

Mixed form: `(start, width, descriptor)` — sometimes easier to read:

```julia
schema = FixedWidthSchema(
    :carrier => (1, 2, FWString()),
    :fnum    => (3, 4, FWInt()),
)
```

## 8. Load schemas from files

Schemas often live next to the data as a CSV, TOML, or JSON file. `load_schema`
reads any of those:

```julia
# flights.csv has columns: name, start, end, type  (plus optional format)
#   carrier,1,2,String
#   flight_num,3,6,Int
#   dep_date,7,14,Date,yyyymmdd
schema = load_schema("flights.csv")

# Same fields as a TOML file
schema = load_schema("flights.toml")

# JSON requires JSON3.jl to be loaded (weakdep)
using JSON3
schema = load_schema("flights.json")
```

## 9. Multi-record files

Some formats pack multiple record types in one file, differentiated by a
discriminator field. SSIM schedules are the canonical example: record types
1–5 identified by the first byte:

```julia
# Two record types, distinguished by byte 1
header = FixedWidthSchema(:rec => (1, FWString()), :title => (9, FWString()))
detail = FixedWidthSchema(:rec => (1, FWString()), :code  => (3, FWString()),
                                                  :value => (6, FWInt()))

ms = MultiRecordSchema(1:1, "H" => header, "D" => detail)

# parse_file returns a Dict{Symbol, StructArray}
result = parse_file("mixed.dat", ms)
result[:H].title   # header rows, titles column
result[:D].value   # detail rows, values column
```

Keys can be `String`, `Char`, or `Int`:

```julia
ms = MultiRecordSchema(1:1, 'H' => header, 'D' => detail)
ms = MultiRecordSchema(1:1, 1   => header, 2   => detail)
```

For lazy iteration, records yield a `_type` field identifying which schema
matched:

```julia
for rec in eachrecord("mixed.dat", ms)
    if rec._type === :H
        println("header: ", rec.title)
    else
        println("detail: ", rec.value)
    end
end
```

### Bundled schemas

Several common aviation formats ship as pre-built schemas:

```julia
using FixedWidthParsers

aircraft = parse_file("aircraft.dat", AIRCRAFT_SCHEMA)
airports = parse_file("airports.dat", AIRPORT_SCHEMA)
ssim     = parse_file("schedule.ssim", SSIM_SCHEMA; on_error = :lenient)

ssim[:type_3]  # flight leg records
```

Available: `SSIM_SCHEMA`, `AIRCRAFT_SCHEMA`, `AIRPORT_SCHEMA`, `MCT_SCHEMA`,
`MCT_PRIORITY_SCHEMA`, `REGIONAL_SCHEMA`, `SEATS_SCHEMA`. See
[`bundled_schemas.jl`](@ref FixedWidthParsers.SSIM_SCHEMA) in the API reference.

## 10. Custom parsers with `FWCustom`

When none of the built-in descriptors fit, plug in your own function:

```julia
# Parse a field as a string and pass to a user function
parse_quantity(s) = (; amount = parse(Int, s[1:5]), unit = s[6:7])
FWCustom(NamedTuple, parse_quantity)

# Or operate on raw bytes (zero-copy)
FWCustom(Float32, (buf, pos, len) -> _my_fast_float(buf, pos, len); raw = true)
```

The `return_type` is stored on the descriptor so column pre-allocation and
DuckDB DDL translation pick the right Julia type.

## What's next

- [Streaming to DuckDB](duckdb.md) — load fixed-width data into a database
  for SQL analysis.
- [User Guide](../guide.md) — consolidated reference for every feature.
- [API Reference](../api.md) — function-level documentation.
