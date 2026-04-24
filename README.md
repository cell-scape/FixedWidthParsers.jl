# FixedWidthParsers.jl

A fast, ergonomic parser for fixed-width text files in Julia. Turns flat
files into columnar `StructArray`s or row iterators with minimal code and
real performance.

- 📊 ~23 M records/s single-threaded, ~80 M rec/s on 8 threads
- 🧱 Runtime (`FixedWidthSchema`) or compile-time (`@fixedwidth`) schemas
- 🦆 First-class DuckDB integration via the `DuckDBExt` package extension
- 📦 Tables.jl interface — works with DataFrames, CSV.jl, Arrow, Parquet
- 🧵 Parallel parsing via `ntasks`
- 🎯 Three error modes: strict, lenient, default

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/cell-scape/FixedWidthParsers.jl")
```

## Quick start

```julia
using FixedWidthParsers

schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
)

sa = parse_file("flights.dat", schema)
sa.carrier  # Vector{String3}
sa.fnum     # Vector{Int64}
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

### In-memory sources

```julia
parse_string(data::AbstractString, schema; kwargs...)
parse_bytes(bytes::Vector{UInt8}, schema; kwargs...)
parse_file(io::IO, schema; kwargs...)
```

### Filters

```julia
parse_file(path, schema;
    skip_header = 1,        # drop first N records
    skip_footer = 1,        # drop last N records
    comment     = UInt8('#'),  # drop records whose first byte matches
    select      = [:carrier, :fnum],
    on_error    = :lenient,    # or :strict (default) or :default
    ntasks      = 4,           # parallel parse tasks
)
```

### Lazy iteration

```julia
for rec in eachrecord("flights.dat", schema)
    rec.carrier == "UA" && println(rec)
end
```

`eachrecord` satisfies Tables.jl's row interface, so it pipes directly into
DataFrames or CSV writers.

## Multi-record files

Some formats pack mixed record types in one file (e.g., SSIM schedules).
Provide a discriminator byte range and a schema per record type:

```julia
ms = MultiRecordSchema(
    1:1,
    "H" => header_schema,
    "D" => detail_schema,
)
result = parse_file("mixed.dat", ms)
result[:H].title
result[:D].value
```

Keys can be `String`, `Char`, or `Int`. Pre-built SSIM, IATA airport, and
aircraft schemas ship as constants: `SSIM_SCHEMA`, `AIRCRAFT_SCHEMA`,
`AIRPORT_SCHEMA`, `MCT_SCHEMA`, `MCT_PRIORITY_SCHEMA`, `REGIONAL_SCHEMA`,
`SEATS_SCHEMA`.

## DuckDB integration

Install `DuckDB.jl` and `DBInterface.jl`, then stream fixed-width files
into a DuckDB table with bounded memory:

```julia
using FixedWidthParsers, DuckDB, DBInterface

db = DBInterface.connect(DuckDB.DB, ":memory:")

to_duckdb(db, "flights", "flights.dat", schema;
    chunk_size = 250_000,     # default; tunable
    nworkers   = 8,           # parallel workers, each with own connection
    on_error   = :lenient,
)

DBInterface.execute(db,
    "SELECT carrier, COUNT(*) FROM flights GROUP BY carrier") |> collect
```

Measured 2.3× speedup on an insert-bound 1M-row narrow schema at 8 workers
(see `benchmark/RESULTS.md`).

## Schema files

Load schemas from CSV, TOML, or JSON (JSON requires `using JSON3`):

```julia
schema = load_schema("flights.csv")
schema = load_schema("flights.toml")
using JSON3; schema = load_schema("flights.json")
```

CSV columns: `name, start, end, type` (plus optional `format` for date types).

## Fast-path date formats

Several common formats dispatch to byte-level parsers that skip Julia's
`DateFormat` interpreter, ~15× faster than the generic path:

```
yyyymmdd       2026-04-01         FWDate("yyyymmdd")
yyyy-mm-dd     2026-04-01         FWDate("yyyy-mm-dd")
dduuuyy        10Jan26            FWDate("dduuuyy")
HHMM, HHMMSS, HH:MM, HH:MM:SS     FWTime(...)
yyyymmddHHMM, yyyymmddHHMMSS      FWDateTime(...)
```

Any other format still works — it just goes through `Dates.DateFormat`.

## Documentation

Full docs (tutorials, user guide, DuckDB extension, performance results, API
reference) build locally:

```bash
julia --project=docs docs/make.jl
open docs/build/index.html
```

Release history: [`CHANGELOG.md`](CHANGELOG.md). Performance results:
[`benchmark/RESULTS.md`](benchmark/RESULTS.md).

## License

MIT.
