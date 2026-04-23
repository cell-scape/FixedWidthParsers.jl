# FixedWidthParsers.jl — Design Document

**Date:** 2026-02-24
**Status:** Approved

## Overview

A high-performance, general-purpose fixed-width file parser for Julia. Uses memory-mapped IO with `@generated` inner loops for maximum throughput, while providing ergonomic APIs for both static (macro-defined) and dynamic (runtime-defined) schemas.

Primary use case: parsing airline operations data (flight schedules, PNR records, leg maps) from the IBPR system, but designed as a fully general library.

## Goals

- **Throughput:** >500 MB/s on commodity hardware for numeric-heavy schemas
- **Memory:** Handle files larger than RAM via mmap (OS-managed paging)
- **Ergonomics:** Declarative schema definition via `@fixedwidth` macro
- **Flexibility:** Runtime schema definition for config-driven parsing
- **Extensibility:** Custom field parser hooks for domain-specific types
- **Interop:** Tables.jl interface for DataFrames/StructArrays integration

## Non-Goals (for v1)

- Writing/formatting fixed-width files (read-only)
- SIMD field boundary detection (future optimization)
- Distributed/multi-node parsing

## Architecture

### Package Structure

```
~/Projects/FixedWidthParsers.jl/
├── Project.toml
├── src/
│   ├── FixedWidthParsers.jl    # Main module, exports
│   ├── schema.jl                # Schema types + @fixedwidth macro
│   ├── io.jl                    # Mmap + chunked IO backends
│   ├── parsing.jl               # Core parsing logic + @generated loops
│   ├── types.jl                 # Field type parsers (Int, String, Date, FixedPoint, custom)
│   ├── iteration.jl             # Lazy iterator interface
│   └── materialization.jl       # Collect into StructArrays / Vector{T}
├── test/
│   ├── runtests.jl
│   ├── test_schema.jl
│   ├── test_parsing.jl
│   ├── test_types.jl
│   ├── test_iteration.jl
│   └── test_materialization.jl
└── bench/
    ├── benchmarks.jl
    └── tune.json
```

### Dependencies

| Package | Purpose |
|---------|---------|
| `Parsers.jl` | Efficient byte-level type parsing |
| `StructArrays.jl` | Columnar output representation |
| `StringViews.jl` | Zero-copy string slices into mmap buffer |
| `Tables.jl` | Interface compliance for DataFrames interop |
| `Mmap` (stdlib) | Memory-mapped file IO |
| `BenchmarkTools.jl` (test) | Microbenchmarking |
| `PkgBenchmark.jl` (test) | Benchmark regression tracking |

## Schema API

### Macro-based (static schemas)

```julia
@fixedwidth struct FlightRecord
    carrier::String        = 2        # 2-char carrier code
    flight_num::Int        = 4        # 4-digit flight number
    _::Skip                = 1        # 1-byte padding (discarded)
    origin::String         = 3        # 3-char airport code
    dest::String           = 3        # 3-char airport code
    dep_date::Date         = 7        # "YYYYDDD" julian date
    pax_count::Int         = 3        # passenger count
    revenue::FixedPoint{2} = 8        # implied 2 decimals: "00012345" → 123.45
end
```

The `@fixedwidth` macro:
1. Rewrites the struct to store parsed Julia types (not raw bytes)
2. Generates a companion `Schema{FlightRecord}` singleton with field widths, offsets, and types
3. Emits a `@generated` parse function specialized to that exact layout

### Runtime specification (dynamic schemas)

```julia
schema = FixedWidthSchema(
    :carrier    => (2, FWString),
    :flight_num => (4, FWInt),
    :skip       => (1, FWSkip),
    :origin     => (3, FWString),
    :dest       => (3, FWString),
    :dep_date   => (7, FWDate("YYYYDDD")),
    :pax_count  => (3, FWInt),
    :revenue    => (8, FWFixedPoint(2)),
)
```

Returns `StructArray` of `NamedTuple`s when materialized.

### Custom field parsers

```julia
FixedWidthParsers.parse_field(::Type{PnrStatus}, bytes, pos, len) = ...
```

Any type with a `parse_field` method can be used as a field type in both macro and runtime schemas.

## IO Layer

### Primary: Memory-Mapped IO

```
File → Mmap.mmap(io, Vector{UInt8}, filesize) → buffer::Vector{UInt8}
```

- Record boundaries are computed arithmetically: record `i` starts at `(i-1) * record_stride`
- `record_stride = sum(field_widths) + newline_width`
- Newline style (`\n` = 1 byte, `\r\n` = 2 bytes) auto-detected from first 2 records

### Fallback: Chunked Read

For non-seekable sources (pipes, stdin, `IOBuffer`):
- Read in 64KB chunks into a reusable buffer
- Process complete records from buffer, carry partial records to next chunk

### Newline Detection

Scan first `record_width + 2` bytes. If byte at `record_width` is `\r` and `record_width + 1` is `\n`, it's CRLF. Otherwise assume LF. Error if neither.

## Parsing Pipeline

```
For each record at byte offset `pos` in buffer:
    For each field (field_offset, width, FieldType):
        slice = @view buffer[pos + field_offset : pos + field_offset + width - 1]
        value = parse_field(FieldType, slice)
```

### Optimizations

1. **No String allocation for numeric fields** — `Parsers.xparse` works directly on byte buffers
2. **StringView for string fields** — zero-copy view into mmap'd buffer, valid while file is open
3. **`@generated` inner loop** — for compile-time-known schemas, the entire record parse unrolls into sequential field extractions with constant offsets. Zero dispatch overhead.
4. **Pre-allocated output** — `StructArray` columns pre-allocated to `filesize ÷ record_stride` elements
5. **Thread-safe parallel parsing** — mmap buffer is read-only shared state; each thread writes to its own slice of the output arrays. Parallelized via `@threads` over record index ranges.

### Runtime schemas

Use a tight loop over `schema.fields::Vector{FieldSpec}` with function barriers to avoid type instability. Slower than `@generated` but still fast (no string allocation for numerics, same zero-copy strings).

## Output Materialization

### Lazy iteration (default)

```julia
for record in eachrecord("file.dat", FlightRecord)
    process(record)
end
```

Returns records one at a time. Parsing happens on `iterate()`. No upfront memory cost.

### StructArray (columnar, recommended for analytics)

```julia
sa = parse_file("file.dat", FlightRecord)  # → StructArray{FlightRecord}
```

Pre-allocates all columns, fills in single pass. Optimal for DataFrames, column-wise operations.

### Vector of structs

```julia
v = parse_file("file.dat", FlightRecord; columnar=false)  # → Vector{FlightRecord}
```

### Tables.jl interface

```julia
using DataFrames
df = DataFrame(parse_file("file.dat", FlightRecord))
```

## Error Handling

| Mode | Behavior |
|------|----------|
| `:strict` (default) | Throw `ParseError` with line number, column range, raw bytes, expected type |
| `:lenient` | Return `missing` for unparseable fields, log warning |
| `:callback` | Call user-provided `on_error(line, col, bytes, err)` function |

Configured via `parse_file(...; on_error=:strict)`.

`ParseError` includes:
- `line::Int` — 1-based line number
- `columns::UnitRange{Int}` — byte range within the record
- `raw_bytes::Vector{UInt8}` — the problematic bytes
- `expected_type::Type` — what we tried to parse as
- `message::String` — human-readable description

## Benchmarking

- **Framework:** `PkgBenchmark.jl` + `BenchmarkTools.jl`
- **Suite location:** `bench/benchmarks.jl`
- **Scenarios:**
  - 1M records, 10 fields (mixed numeric/string)
  - 1M records, all-numeric (best case for zero-alloc parsing)
  - 100K records with variable newline styles
  - Large file (1GB+) mmap throughput
- **CI integration:** Run benchmarks on PRs, compare against `main` baseline
- **Target:** >500 MB/s for numeric-heavy, >300 MB/s for string-heavy schemas

## Future Work (post-v1)

- Write/format support
- SIMD newline scanning and field validation
- `@simd` / `@turbo` for numeric column parsing
- Distributed parsing for multi-GB files
- Schema inference from sample data
