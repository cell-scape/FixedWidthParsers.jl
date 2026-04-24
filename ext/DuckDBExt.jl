"""
    DuckDBExt — FixedWidthParsers.jl ↔ DuckDB.jl integration.

Provides [`FixedWidthParsers.to_duckdb`](@ref): stream-parse a fixed-width
file (or `IO`) into a DuckDB table in bounded-memory chunks.

Loaded automatically when both `FixedWidthParsers` and `DuckDB` are active.

# Example

```julia
using FixedWidthParsers, DuckDB, DBInterface

schema = FixedWidthSchema(
    :carrier    => (2, FWString()),
    :flight_num => (4, FWInt()),
    :origin     => (3, FWString()),
)

con = DBInterface.connect(DuckDB.DB, ":memory:")
to_duckdb(con, "flights", "flights.dat", schema; chunk_size = 100_000)

DBInterface.execute(con, "SELECT carrier, COUNT(*) FROM flights GROUP BY carrier") |> collect
```
"""
module DuckDBExt

using FixedWidthParsers
using FixedWidthParsers: FixedWidthSchema, FieldSpec
using FixedWidthParsers: FWString, FWInt, FWFloat, FWDate, FWTime, FWDateTime,
    FWFixedPoint, FWBool, FWCustom, FWSkip
using FixedWidthParsers: MmapSource, ChunkedSource, AbstractSource
using FixedWidthParsers: record_width, record_count, buffer
using FixedWidthParsers: _apply_column_selection, _valid_record_indices,
    _parse_columnar_indexed, _partition_ranges, _rethrow_unwrapped

using DuckDB
using DBInterface
using Dates

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

"""
    to_duckdb(con, table_name, path, schema; kwargs...)

Parse a fixed-width file and write it to a DuckDB table in `chunk_size`-row
chunks, never holding more than one chunk in memory.

- `con`          : DuckDB connection or `DuckDB.DB` handle.
- `table_name`   : target table name (quoted internally).
- `path`         : fixed-width file path.
- `schema`       : `FixedWidthSchema`.

# Keyword arguments

- `chunk_size::Int = 250_000` — records per parse-and-insert pass. DuckDB's
  columnar ingestion has per-INSERT fixed overhead, so very small chunks
  (≲ 100k) pay a cost without bound; very large chunks raise peak memory
  but are otherwise fine. 250k is the sweet spot on a 24-byte schema.
- `create_table::Bool = true` — run `CREATE TABLE` before appending.
- `replace_table::Bool = false` — use `CREATE OR REPLACE TABLE` when creating.
- `on_error::Symbol = :strict` — `:strict`, `:lenient`, or `:default`
  (see `parse_file` docs).
- `ntasks::Int = 1` — parallel parse tasks per chunk.
- `nworkers::Int = 1` — parallel worker tasks, each with its own DuckDB
  connection, splitting the record range K ways. Requires `con` to be a
  `DuckDB.DB` (as returned by `DBInterface.connect(DuckDB.DB, path)`);
  if you pass a `DuckDB.Connection`, only `nworkers = 1` is supported.

  The parallel path uses `DuckDB.Appender` per worker, not
  `register_data_frame` + `INSERT`. DuckDB.jl stores registered Tables
  sources in a Dict on the shared DB that is not thread-safe, whereas
  Appender state lives on the per-worker Connection. As a result,
  `nworkers=1` (sequential `register + INSERT`) is the fastest path for
  small / fast-insert workloads (e.g. date-only schemas). `nworkers > 1`
  is a net win only when INSERT is the dominant phase (string/int-heavy
  schemas with many rows); measured ~2.3× at 8 workers on a 7-field
  narrow schema. Measure your workload.
- `skip_header::Int = 0`, `skip_footer::Int = 0` — rows to drop.
- `comment::Union{UInt8, Nothing} = nothing` — records starting with this
  byte are filtered.
- `select` / `exclude` — column selection (mutually exclusive).

Returns `table_name`.

# Error handling

An exception during streaming leaves any already-inserted chunks in the
target table (no implicit transaction). Wrap the call in your own
`BEGIN TRANSACTION` / `COMMIT` / `ROLLBACK` if atomicity is required.
"""
function FixedWidthParsers.to_duckdb(
    con,
    table_name::AbstractString,
    path::AbstractString,
    schema::FixedWidthSchema;
    chunk_size::Int = 250_000,
    create_table::Bool = true,
    replace_table::Bool = false,
    on_error::Symbol = :strict,
    ntasks::Int = 1,
    nworkers::Int = 1,
    skip_header::Int = 0,
    skip_footer::Int = 0,
    comment::Union{UInt8, Nothing} = nothing,
    select::Union{AbstractVector{Symbol}, Nothing} = nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing} = nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    if create_table
        DBInterface.execute(con, _ddl_from_schema(table_name, schema; replace = replace_table))
    end
    src = MmapSource(path, record_width(schema))
    try
        _stream_dispatch!(con, table_name, src, schema, chunk_size, on_error, ntasks,
            nworkers, skip_header, skip_footer, comment)
    finally
        close(src)
    end
    return table_name
end

"""
    to_duckdb(con, table_name, io::IO, schema; kwargs...)

IO overload — reads the entire stream into memory (via `ChunkedSource`)
before chunk-inserting into DuckDB. For file paths prefer the
path-based method, which uses `mmap` and is truly bounded-memory.
"""
function FixedWidthParsers.to_duckdb(
    con,
    table_name::AbstractString,
    io::IO,
    schema::FixedWidthSchema;
    chunk_size::Int = 250_000,
    create_table::Bool = true,
    replace_table::Bool = false,
    on_error::Symbol = :strict,
    ntasks::Int = 1,
    nworkers::Int = 1,
    skip_header::Int = 0,
    skip_footer::Int = 0,
    comment::Union{UInt8, Nothing} = nothing,
    select::Union{AbstractVector{Symbol}, Nothing} = nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing} = nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    if create_table
        DBInterface.execute(con, _ddl_from_schema(table_name, schema; replace = replace_table))
    end
    src = ChunkedSource(io, record_width(schema))
    try
        _stream_dispatch!(con, table_name, src, schema, chunk_size, on_error, ntasks,
            nworkers, skip_header, skip_footer, comment)
    finally
        close(src)
    end
    return table_name
end

# ---------------------------------------------------------------------------
# Streaming core
# ---------------------------------------------------------------------------

function _stream_dispatch!(con, table_name, src::AbstractSource, schema, chunk_size,
        on_error, ntasks, nworkers, skip_header, skip_footer, comment)
    n = record_count(src)
    n == 0 && return nothing
    buf = buffer(src)

    raw_indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    indices = raw_indices === nothing ? collect(1:n) : raw_indices
    isempty(indices) && return nothing

    if nworkers <= 1
        _insert_sequential!(con, table_name, src, buf, schema, indices,
            chunk_size, on_error, ntasks)
    else
        con isa DuckDB.DB ||
            throw(ArgumentError("nworkers > 1 requires `con` to be a DuckDB.DB " *
                "(e.g. `DBInterface.connect(DuckDB.DB, \":memory:\")`); " *
                "got $(typeof(con)). Use `nworkers = 1` to keep using a Connection."))
        _insert_parallel!(con, table_name, src, buf, schema, indices,
            chunk_size, on_error, ntasks, nworkers)
    end
    return nothing
end

# Sequential path — single connection, chunks processed serially.
function _insert_sequential!(con, table_name, src, buf, schema, indices,
        chunk_size, on_error, ntasks)
    view_name = _unique_view_name(con)
    quoted_tgt  = string('"', _escape_ident(String(table_name)), '"')
    quoted_view = string('"', _escape_ident(view_name), '"')
    insert_sql  = string("INSERT INTO ", quoted_tgt, " SELECT * FROM ", quoted_view)

    for chunk_start in 1:chunk_size:length(indices)
        chunk_end = min(chunk_start + chunk_size - 1, length(indices))
        chunk_idx = indices[chunk_start:chunk_end]
        sa = _parse_columnar_indexed(schema, src, buf, chunk_idx, on_error, ntasks)
        DuckDB.register_data_frame(con, sa, view_name)
        try
            DBInterface.execute(con, insert_sql)
        finally
            DuckDB.unregister_data_frame(con, view_name)
        end
    end
    return nothing
end

# Parallel path — partition indices into nworkers contiguous slices,
# each worker owns a dedicated DuckDB connection and processes its slice
# in chunk_size sub-chunks via register_data_frame + INSERT.
#
# Error propagation: if any worker throws, `@sync` collects the errors;
# `_rethrow_unwrapped` peels the CompositeException / TaskFailedException
# layers so users see the original ParseError or DuckDB error directly.
#
# Atomicity: DuckDB concurrent INSERTs against the same table commit
# row-by-row (no implicit transaction across workers). A mid-stream
# failure leaves already-inserted rows from successful workers. Wrap
# the to_duckdb call in a BEGIN/COMMIT explicitly if you need rollback.
function _insert_parallel!(db::DuckDB.DB, table_name, src, buf, schema, indices,
        chunk_size, on_error, ntasks, nworkers)
    n_idx = length(indices)
    slices = _partition_ranges(n_idx, nworkers)
    try
        @sync for slice in slices
            Threads.@spawn _worker_insert!(db, table_name, src, buf, schema, indices,
                slice, chunk_size, on_error, ntasks)
        end
    catch e
        _rethrow_unwrapped(e)
    end
    return nothing
end

function _worker_insert!(db::DuckDB.DB, table_name, src, buf, schema, indices,
        slice::UnitRange{Int}, chunk_size, on_error, ntasks)
    # Workers use Appender rather than register_data_frame + INSERT because
    # DuckDB.jl's register_table stores the Tables source in a non-thread-safe
    # Dict on the shared DB (`con.db.registered_objects`). Concurrent workers
    # race on that Dict. Appender state is held on the per-worker Connection,
    # so K workers with K Appenders have no shared Julia-side state to race on.
    con = DBInterface.connect(db)
    try
        appender = DuckDB.Appender(con, table_name)
        try
            slice_len = length(slice)
            for sub_start in 1:chunk_size:slice_len
                sub_end = min(sub_start + chunk_size - 1, slice_len)
                lo = first(slice) + sub_start - 1
                hi = first(slice) + sub_end  - 1
                chunk_idx = indices[lo:hi]
                sa = _parse_columnar_indexed(schema, src, buf, chunk_idx, on_error, ntasks)
                _append_structarray!(appender, sa)
            end
        finally
            DuckDB.close(appender)
        end
    finally
        DBInterface.close!(con)
    end
    return nothing
end

# Per-row, per-value append into a DuckDB.Appender. `sa` is a concrete
# StructArray; `sa[i]` returns a concrete NamedTuple so the inner loop is
# fully type-stable. `missing` values dispatch to the Appender's NULL path.
function _append_structarray!(appender, sa)
    n = length(sa)
    @inbounds for i in 1:n
        row = sa[i]
        for v in values(row)
            DuckDB.append(appender, v)
        end
        DuckDB.end_row(appender)
    end
    return nothing
end

# Unique-ish view name per call so concurrent callers on the same DB
# don't collide. Collisions would manifest as a DuckDB error on register,
# not silent corruption — but an extra digit is cheap insurance.
@inline _unique_view_name(con) =
    string("__fwp_chunk_view_", objectid(con), "_", time_ns())

# ---------------------------------------------------------------------------
# FixedWidthSchema → DuckDB DDL
# ---------------------------------------------------------------------------

function _ddl_from_schema(table_name::AbstractString, schema::FixedWidthSchema;
        replace::Bool = false)
    cols = String[]
    for f in schema._output_fields
        f.type isa FWSkip && continue  # belt-and-suspenders; _output_fields already excludes FWSkip
        push!(cols, string('"', _escape_ident(String(f.name)), '"', ' ', _duckdb_type(f.type)))
    end
    verb = replace ? "CREATE OR REPLACE TABLE" : "CREATE TABLE"
    return string(verb, ' ', '"', _escape_ident(String(table_name)), '"',
        ' ', '(', join(cols, ", "), ')')
end

# Escape embedded quotes by doubling, per SQL identifier rules.
@inline _escape_ident(s::AbstractString) = replace(s, '"' => "\"\"")

_duckdb_type(::FWString)     = "VARCHAR"
_duckdb_type(::FWInt)        = "BIGINT"
_duckdb_type(::FWFloat)      = "DOUBLE"
_duckdb_type(::FWFixedPoint) = "DOUBLE"
_duckdb_type(::FWBool)       = "BOOLEAN"
_duckdb_type(::FWDate)       = "DATE"
_duckdb_type(::FWTime)       = "TIME"
_duckdb_type(::FWDateTime)   = "TIMESTAMP"

function _duckdb_type(d::FWCustom)
    T = d.return_type
    T <: AbstractString  && return "VARCHAR"
    T <: Integer         && return "BIGINT"
    T <: AbstractFloat   && return "DOUBLE"
    T === Bool           && return "BOOLEAN"
    T === Date           && return "DATE"
    T === Time           && return "TIME"
    T === DateTime       && return "TIMESTAMP"
    return "VARCHAR"  # fallback: let DuckDB coerce via string representation
end

# Defensive fallback for any descriptor the extension doesn't recognize.
_duckdb_type(::Any) = "VARCHAR"

end # module DuckDBExt
