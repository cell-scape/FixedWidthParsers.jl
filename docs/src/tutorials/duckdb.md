# Tutorial: Streaming to DuckDB

DuckDB is an in-process analytical database with a rich SQL dialect — a
perfect landing spot for fixed-width data you want to query, join, or
aggregate. This tutorial shows how to stream a fixed-width file into a
DuckDB table with bounded memory, then run SQL against it.

Prerequisites: the [Quick Start](quickstart.md) tutorial covers schemas
and basic `parse_file` usage.

## 1. Install DuckDB + DBInterface

The DuckDB integration is a **package extension** — it only loads when both
`DuckDB.jl` and `DBInterface.jl` are in your environment. Install them in
the project where you use FixedWidthParsers:

```julia
using Pkg
Pkg.add(["DuckDB", "DBInterface"])
```

Then `using DuckDB` — which pulls in `DBInterface` transitively — activates
the extension. `to_duckdb` becomes available:

```julia
using FixedWidthParsers, DuckDB, DBInterface
```

## 2. First load

Let's build a small flight file and stream it in:

```julia
# Generate a 10-row sample file
path = tempname() * ".dat"
open(path, "w") do io
    for (i, (c, fn, o, d, px)) in enumerate([
        ("UA", 1234, "ORD", "SFO",  150),
        ("DL",  567, "LAX", "JFK",  220),
        ("AA",  999, "SFO", "ORD",  187),
        ("UA", 1235, "ORD", "LAX",  210),
        ("WN", 1101, "DEN", "SFO",   95),
    ])
        println(io, c, lpad(fn, 4), o, d, lpad(px, 4))
    end
end

schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :origin  => (3, FWString()),
    :dest    => (3, FWString()),
    :pax     => (4, FWInt()),
)

# Open an in-memory DuckDB
db = DBInterface.connect(DuckDB.DB, ":memory:")

# Stream the file into a table
to_duckdb(db, "flights", path, schema)
```

That single call:

1. Generates a `CREATE TABLE flights (carrier VARCHAR, fnum BIGINT, origin VARCHAR, dest VARCHAR, pax BIGINT)` DDL from the schema and runs it.
2. Opens the file via `mmap`.
3. Parses the records in `chunk_size`-row batches (default 250 000).
4. Ingests each batch into DuckDB using the columnar `register_data_frame + INSERT` path.

Peak memory stays bounded to ~one chunk — you can process multi-GB files
without loading them entirely into RAM.

## 3. Query with SQL

Now you've got a real relational table:

```julia
rows = DBInterface.execute(db, """
    SELECT carrier, COUNT(*) AS n, SUM(pax) AS total_pax
    FROM flights
    GROUP BY carrier
    ORDER BY total_pax DESC
""") |> collect

for r in rows
    println(r.carrier, " → ", r.n, " flights, ", r.total_pax, " passengers")
end
```

```
UA → 2 flights, 360 passengers
DL → 1 flights, 220 passengers
AA → 1 flights, 187 passengers
WN → 1 flights, 95 passengers
```

Or join against another table (maybe airport lookup data loaded the same way):

```julia
to_duckdb(db, "airports", "airports.dat", AIRPORT_SCHEMA)

DBInterface.execute(db, """
    SELECT f.carrier, f.fnum, a.metro_area AS origin_metro
    FROM flights f
    JOIN airports a ON f.origin = a.airport
""") |> collect
```

## 4. The type mapping

DuckDB columns are typed from your schema:

| FixedWidthParsers descriptor | DuckDB type |
|------------------------------|-------------|
| `FWString`                   | `VARCHAR`   |
| `FWInt`                      | `BIGINT`    |
| `FWFloat`, `FWFixedPoint`    | `DOUBLE`    |
| `FWBool`                     | `BOOLEAN`   |
| `FWDate`                     | `DATE`      |
| `FWTime`                     | `TIME`      |
| `FWDateTime`                 | `TIMESTAMP` |
| `FWCustom{F, D}`             | inferred from `return_type` |

`:lenient` mode parses failed fields as NULL in DuckDB.

## 5. Control the load

All the usual `parse_file` kwargs work with `to_duckdb`:

```julia
to_duckdb(db, "flights", path, schema;
    skip_header  = 2,
    skip_footer  = 1,
    comment      = UInt8('#'),
    on_error     = :lenient,
    select       = [:carrier, :fnum, :pax],
    chunk_size   = 500_000,       # bigger chunks, fewer round-trips
    create_table = true,          # CREATE TABLE; false = append to existing
    replace_table = false,        # true = CREATE OR REPLACE TABLE
)
```

The `chunk_size` default (250 000) is the measured sweet spot on a narrow
schema — small enough to keep memory bounded, large enough to amortize
DuckDB's per-`INSERT` overhead. For very wide schemas you might want to
shrink it; for very narrow ones you can raise it.

## 6. Parallel loading with `nworkers`

For large files on multi-core machines, hand work to multiple concurrent
DuckDB connections:

```julia
to_duckdb(db, "flights", "huge.dat", schema; nworkers = 8)
```

Each worker owns a dedicated connection and `DuckDB.Appender`, and fills its
disjoint slice of the file. Measured on a 1M-row narrow schema (8-thread
machine):

|           | Time   | Throughput     |
|-----------|-------:|---------------:|
| nworkers=1 | 239 ms | 4.2 M rec/s    |
| nworkers=4 | 141 ms | 7.1 M rec/s    |
| **nworkers=8** | **104 ms** | **9.6 M rec/s** |

### When `nworkers` helps

- Many rows, string/int-heavy columns (insert-bound workloads).
- Machine has idle cores.

### When it doesn't

- Date-heavy schemas, where single-threaded `to_duckdb` is already
  close to the compute floor. On a dates-only 1M-row file, `nworkers=8`
  only buys ~1.2×.
- Small files, where connection-setup overhead dominates.
- Files you'd rather process with DuckDB's native CSV reader (if the
  format is actually CSV).

### Why Appender for parallel, `register_data_frame` for sequential?

Under the hood the sequential (`nworkers=1`) path uses DuckDB's columnar
`register_data_frame` + `INSERT` — it's ~1.77× faster than row-wise
`Appender` on a single thread. But `register_data_frame` stores registered
Tables sources in a `Dict` on the shared `DuckDB.DB` that isn't thread-safe;
concurrent workers race on that state. `DuckDB.Appender` holds state on the
per-worker `Connection` so K workers have no contention. The extension
auto-selects.

!!! note "nworkers requires a `DuckDB.DB`, not a `Connection`"
    To spawn sibling connections we need the parent DB object. Pass the
    result of `DBInterface.connect(DuckDB.DB, ...)` directly. If you hold
    only a `DuckDB.Connection`, the extension will throw a clear
    `ArgumentError` — use `nworkers = 1` or switch to a `DuckDB.DB`.

## 7. Appending to an existing table

By default `to_duckdb` creates the table. To append to a table you've
created yourself (or loaded from a previous `to_duckdb` call):

```julia
DBInterface.execute(db, """
    CREATE TABLE flights (
        carrier VARCHAR, fnum BIGINT, origin VARCHAR, dest VARCHAR, pax BIGINT
    )
""")

to_duckdb(db, "flights", "jan.dat", schema; create_table = false)
to_duckdb(db, "flights", "feb.dat", schema; create_table = false)
to_duckdb(db, "flights", "mar.dat", schema; create_table = false)
```

To recreate a table from scratch every time (useful during iteration):

```julia
to_duckdb(db, "flights", path, schema; replace_table = true)
```

## 8. When to skip `to_duckdb`

For small files (say under a few hundred thousand rows) that fit comfortably
in memory, it can be just as clean to materialize first and register:

```julia
sa = parse_file(path, schema)

DuckDB.register_data_frame(db, sa, "flights_view")
DBInterface.execute(db, """
    SELECT carrier, COUNT(*) FROM flights_view GROUP BY carrier
""") |> collect
```

`register_data_frame` creates a zero-copy view over the `StructArray`, so
no data copy happens until you INSERT. This is slightly more flexible (you
can inspect `sa` first) but doesn't stream — you hold the whole file in
memory.

Rule of thumb: **use `to_duckdb` when the file might not fit in RAM or you
want `nworkers` concurrency; use `parse_file` + `register_data_frame` for
iterating in a notebook.**

## What's next

- [DuckDB Extension reference](../duckdb.md) — every kwarg and concept
  explained.
- [Performance](../performance.md) — measured throughput for different
  workloads.
