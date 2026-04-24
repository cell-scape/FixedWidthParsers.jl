# FixedWidthParsers.jl

A fast, ergonomic parser for fixed-width text files in Julia.

Fixed-width formats are everywhere in finance, aviation, government, healthcare,
and legacy enterprise systems — they're simple, portable, and often the only
way to receive bulk data from older systems. FixedWidthParsers.jl turns
those flat files into columnar Julia structures (`StructArray`s) or row
iterators with minimal code and real performance.

## At a glance

```julia
using FixedWidthParsers

schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
)

sa = parse_file("flights.dat", schema)

sa.carrier  # Vector of airline codes
sa.fnum     # Vector of flight numbers
```

For a 1M-record file that's **23.5 M records/sec single-threaded, 79.6 M rec/s
on 8 threads** (see [Performance](performance.md)).

## Where to go next

| If you want to…                              | Read                                                    |
|----------------------------------------------|---------------------------------------------------------|
| Learn the basics with a runnable example     | [Tutorial · Quick Start](tutorials/quickstart.md)       |
| Handle messy real-world files                | [Tutorial · Handling Real Data](tutorials/real_data.md) |
| Load fixed-width data into DuckDB for SQL    | [Tutorial · Streaming to DuckDB](tutorials/duckdb.md)   |
| Understand every feature, kwarg, and type    | [User Guide](guide.md)                                  |
| Integrate with DuckDB programmatically       | [DuckDB Extension](duckdb.md)                           |
| See throughput numbers and profiling results | [Performance](performance.md)                           |
| Look up a specific function or type          | [API Reference](api.md)                                 |

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/cell-scape/FixedWidthParsers.jl")
```

The package has a small, pure-Julia core. Two optional integrations load
automatically when you bring their dependencies:

- `using JSON3` — enables `load_schema("myschema.json")`
- `using DuckDB, DBInterface` — enables [`to_duckdb`](@ref)

## Highlights

- **Runtime and compile-time schemas** — `FixedWidthSchema(...)` for dynamic
  schemas, `@fixedwidth struct` for static ones with type-specialized parsing.
- **Columnar and row-oriented output** — `parse_file` returns a `StructArray`
  (zero-copy `InlineString` columns) or a typed `Vector{NamedTuple}` when
  `columnar=false`.
- **Lazy iteration** — `eachrecord(path, schema)` yields one record at a
  time and works as a `Tables.jl` row source.
- **Parallel parsing** — `ntasks=N` splits the file across threads.
- **Multi-record files** — [`MultiRecordSchema`](@ref) for files like SSIM
  where each line can be one of several record types, identified by a
  discriminator field.
- **Byte-range and width schemas** — specify fields as widths, `start:end`
  ranges, or `(start, width)` tuples.
- **Schema files** — load from CSV, TOML, or JSON.
- **DuckDB extension** — [`to_duckdb`](@ref) streams a fixed-width file
  into a DuckDB table in bounded memory, with optional concurrent workers.
- **Flexible error handling** — strict, lenient (missing on error), or
  default-value modes.

## Version

This documentation is for **v0.3.0**. See `CHANGELOG.md` for release notes.
