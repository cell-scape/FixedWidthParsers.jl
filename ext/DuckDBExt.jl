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
    _parse_columnar_indexed

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

- `chunk_size::Int = 100_000` — records per parse-and-append pass.
- `create_table::Bool = true` — run `CREATE TABLE` before appending.
- `replace_table::Bool = false` — use `CREATE OR REPLACE TABLE` when creating.
- `on_error::Symbol = :strict` — `:strict`, `:lenient`, or `:default`
  (see `parse_file` docs).
- `ntasks::Int = 1` — parallel parse tasks per chunk.
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
    chunk_size::Int = 100_000,
    create_table::Bool = true,
    replace_table::Bool = false,
    on_error::Symbol = :strict,
    ntasks::Int = 1,
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
        _stream_into_table!(con, table_name, src, schema, chunk_size, on_error, ntasks,
            skip_header, skip_footer, comment)
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
    chunk_size::Int = 100_000,
    create_table::Bool = true,
    replace_table::Bool = false,
    on_error::Symbol = :strict,
    ntasks::Int = 1,
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
        _stream_into_table!(con, table_name, src, schema, chunk_size, on_error, ntasks,
            skip_header, skip_footer, comment)
    finally
        close(src)
    end
    return table_name
end

# ---------------------------------------------------------------------------
# Streaming core
# ---------------------------------------------------------------------------

function _stream_into_table!(con, table_name, src::AbstractSource, schema, chunk_size,
        on_error, ntasks, skip_header, skip_footer, comment)
    n = record_count(src)
    n == 0 && return nothing
    buf = buffer(src)

    raw_indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    indices = raw_indices === nothing ? collect(1:n) : raw_indices
    isempty(indices) && return nothing

    appender = DuckDB.Appender(con, table_name)
    try
        for chunk_start in 1:chunk_size:length(indices)
            chunk_end = min(chunk_start + chunk_size - 1, length(indices))
            chunk_idx = indices[chunk_start:chunk_end]
            sa = _parse_columnar_indexed(schema, src, buf, chunk_idx, on_error, ntasks)
            _append_structarray!(appender, sa)
        end
    finally
        DuckDB.close(appender)
    end
    return nothing
end

# Iterates a StructArray row by row, emitting values into the Appender.
# `sa[i]` returns a NamedTuple with concrete types; `values(nt)` gives us
# a Tuple we can iterate. DuckDB.append has methods for all common Julia
# scalar types plus `Missing` → NULL.
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
