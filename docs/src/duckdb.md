# DuckDB Extension

FixedWidthParsers.jl ships a package extension, `DuckDBExt`, that activates
when both [`DuckDB.jl`](https://github.com/duckdb/duckdb-julia) and
[`DBInterface.jl`](https://github.com/JuliaDatabases/DBInterface.jl) are
loaded. The extension exposes one public function, [`to_duckdb`](@ref),
which streams a fixed-width file into a DuckDB table in bounded memory
chunks.

For a tutorial-style introduction, see
[Streaming to DuckDB](tutorials/duckdb.md).

## Enabling the extension

Install the weakdeps in your project, then load both:

```julia
using Pkg
Pkg.add(["DuckDB", "DBInterface"])

using FixedWidthParsers, DuckDB, DBInterface
```

Loading `DuckDB` pulls `DBInterface` in transitively, so in practice
`using DuckDB` is enough. Once both are visible, `to_duckdb` dispatches
to the extension's implementation.

If `DuckDB` isn't loaded, `to_duckdb(...)` raises a `MethodError` rather
than silently failing — the function is declared as a stub in the core
module (`function to_duckdb end`) and only gains methods when the
extension activates.

## What `to_duckdb` does

`to_duckdb(con, table_name, source, schema; kwargs...)` does three things:

1. **Schema → DDL.** Translates the `FixedWidthSchema` into a `CREATE TABLE`
   DDL, mapping each descriptor to its DuckDB column type (see table below).
   Runs the DDL unless you opt out with `create_table = false`.

2. **Chunked streaming parse.** Opens the file via `MmapSource` (or
   `ChunkedSource` for an `IO` argument), splits the valid-record indices
   into `chunk_size`-row batches, and parses each batch via the columnar
   `_parse_columnar_indexed` path. Peak memory is bounded to one chunk.

3. **Ingestion.** For sequential (`nworkers = 1`), uses DuckDB's columnar
   `register_data_frame + INSERT SELECT` path. For parallel (`nworkers > 1`),
   uses per-worker `DuckDB.Appender`s on dedicated connections.

## Type mapping

| Schema descriptor              | DuckDB column type                 |
|--------------------------------|------------------------------------|
| `FWString`                     | `VARCHAR`                          |
| `FWInt`                        | `BIGINT`                           |
| `FWFloat`, `FWFixedPoint`      | `DOUBLE`                           |
| `FWBool`                       | `BOOLEAN`                          |
| `FWDate`                       | `DATE`                             |
| `FWTime`                       | `TIME`                             |
| `FWDateTime`                   | `TIMESTAMP`                        |
| `FWCustom{F, D}`               | derived from `D.return_type`       |
| (unknown descriptor fallback)  | `VARCHAR`                          |

`FWSkip` fields don't appear in the table — they're omitted from the DDL
and from the Tables.jl source that feeds into DuckDB.

## Sources

### File path (recommended for large files)

```julia
to_duckdb(db, "flights", "flights.dat", schema)
```

Uses `mmap` internally. The OS handles paging, so reading a 10 GB file
doesn't require 10 GB of RAM.

### `IO` stream

```julia
io = IOBuffer(fetch_from_s3())
to_duckdb(db, "flights", io, schema)
```

The IO overload reads the whole stream into memory (`ChunkedSource`)
before chunking. Use this for pipes, `IOBuffer`s, and `HTTP` responses.
For files, prefer the path overload.

## Keyword arguments

Most mirror the `parse_file` kwargs; the DuckDB-specific ones control
table creation and parallelism.

### Parsing (shared with `parse_file`)

- `on_error::Symbol = :strict` — `:strict`, `:lenient`, `:default`.
  `:lenient` fills failed fields as `NULL` in DuckDB.
- `ntasks::Int = 1` — parallel parse tasks **per chunk**. This
  parallelizes the parse work within a single chunk, not across chunks.
- `skip_header::Int = 0` / `skip_footer::Int = 0`
- `comment::Union{UInt8, Nothing} = nothing`
- `select::Union{AbstractVector{Symbol}, Nothing}` /
  `exclude::Union{AbstractVector{Symbol}, Nothing}`

### DDL / table lifecycle

- `create_table::Bool = true` — run `CREATE TABLE` before ingesting.
  Set to `false` to append to an existing table.
- `replace_table::Bool = false` — use `CREATE OR REPLACE TABLE` when
  creating. Useful during iteration.

### Chunking and concurrency

- `chunk_size::Int = 250_000` — records per parse-and-insert batch. DuckDB's
  `INSERT` has a ~20 ms fixed cost per call, so very small chunks pay a
  multiplicative overhead. 250 000 is the measured sweet spot on a narrow
  7-field schema; very wide schemas may prefer smaller, very narrow ones
  larger.
- `nworkers::Int = 1` — parallel worker tasks, each with its own DuckDB
  connection. See [Parallelism](#parallelism) below.

## Parallelism

### When it helps

| Workload type            | Expected win at `nworkers = 8` |
|--------------------------|--------------------------------|
| String/int-heavy bulk load | ~2.3× (measured on narrow 1M)  |
| Date-heavy schema        | ~1.2× (already near compute floor) |
| Small file (<100k rows)  | negligible or negative          |

### Requirements

`nworkers > 1` requires `con` to be a `DuckDB.DB` — the parent object
from which sibling connections can be spawned. The usual construction
pattern returns one:

```julia
db = DBInterface.connect(DuckDB.DB, ":memory:")
# db isa DuckDB.DB → nworkers = N is fine
```

If you hold only a `DuckDB.Connection`, pass a different DB handle or
stick with `nworkers = 1`. The extension raises a clear `ArgumentError`
in the wrong-type case.

### Why Appender for parallel, `register_data_frame` for sequential?

DuckDB.jl's `register_data_frame` stores the registered Tables source in a
plain Julia `Dict` on the shared `DuckDB.DB` — `con.db.registered_objects[name] = ...`.
Concurrent `register`/`unregister` calls from different workers race on that
Dict and can fail with `KeyError` during unregister. `DuckDB.Appender` state
is held on the per-worker `Connection`, so per-worker appenders are safe.

The downside is that `Appender` is ~1.77× slower than `register_data_frame`
single-threaded (per-value FFI crossings vs per-column). For workloads
where that sequential advantage matters more than parallelism — especially
fast-insert date schemas — leave `nworkers = 1`.

## Error handling and atomicity

`to_duckdb` does **not** wrap the load in a transaction. A `ParseError` or
DuckDB error mid-stream leaves already-inserted chunks in the target
table. If you need atomic loads, wrap the call yourself:

```julia
DBInterface.execute(db, "BEGIN TRANSACTION")
try
    to_duckdb(db, "flights", path, schema)
    DBInterface.execute(db, "COMMIT")
catch
    DBInterface.execute(db, "ROLLBACK")
    rethrow()
end
```

For parallel loads (`nworkers > 1`), each worker auto-commits its own
inserts as DuckDB's MVCC dictates. Explicit transactions across multiple
workers aren't currently supported.

## Interop with the ecosystem

`to_duckdb` is convenient but not the only way to get fixed-width data
into DuckDB. Because `parse_file` returns a Tables.jl-compatible
`StructArray`, the DuckDB.jl native APIs work too:

```julia
sa = parse_file(path, schema)

# Register as a view (zero-copy, no INSERT needed)
DuckDB.register_data_frame(db, sa, "flights_view")

# Query directly
DBInterface.execute(db, "SELECT carrier, COUNT(*) FROM flights_view GROUP BY carrier") |> collect
```

Use this for exploratory work on small files. `to_duckdb` is the right
choice when:

- The file is large enough that you want bounded memory.
- You want `nworkers` concurrency.
- You want the schema-to-DDL translation done for you.

## See also

- [`to_duckdb`](@ref) — API reference.
- [Tutorial · Streaming to DuckDB](tutorials/duckdb.md) — runnable walkthrough.
- [DuckDB.jl documentation](https://duckdb.org/docs/current/clients/tertiary_clients/julia.html).
