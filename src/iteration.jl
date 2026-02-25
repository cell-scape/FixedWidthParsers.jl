"""
    RecordIterator{S}

Lazy iterator over fixed-width records from any `AbstractSource`.

Records are parsed on each `iterate()` call — no upfront allocation of all
records occurs. The underlying source is held for the lifetime of the
iterator and must be released by calling `close(iter)` when iteration is
complete (or by letting GC finalize it).

Type parameter `S` is the concrete `FixedWidthSchema` type, allowing the
compiler to fully specialize `iterate` for the given schema layout.

Works with both `MmapSource` (file-backed) and `ChunkedSource` (IO-backed).
"""
struct RecordIterator{S}
    source::AbstractSource
    schema::S
    indices::Union{Vector{Int}, Nothing}  # nothing = use all records
end

"""
    eachrecord(path::AbstractString, schema::FixedWidthSchema;
               skip_header=0, skip_footer=0, comment=nothing,
               select=nothing, exclude=nothing) → RecordIterator

Return a lazy iterator over every record in the fixed-width file at `path`.

The file is memory-mapped once when `eachrecord` is called. Records are then
parsed on demand as the iterator advances — no work is done until the first
call to `iterate`. This makes it efficient to break out of a loop early.

Call `close(iter)` to release the mmap and file handle when you are done, or
use `collect` which will trigger GC finalization.

# Keyword Arguments
- `skip_header=0`   — skip the first N records (e.g. column headers)
- `skip_footer=0`   — skip the last N records (e.g. summary/trailer lines)
- `comment=nothing` — a `UInt8` byte; skip records whose first byte matches
                       (e.g. `comment=UInt8('#')` to skip comment lines).
                       Comment records must occupy the same fixed width as data records.
- `select=nothing`  — `Vector{Symbol}` of columns to include (others become `FWSkip`)
- `exclude=nothing` — `Vector{Symbol}` of columns to exclude (mutually exclusive with `select`)

# Example

```julia
schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :flight  => (4, FWInt()),
)

for rec in eachrecord("flights.dat", schema)
    println(rec.carrier, rec.flight)
end

# Skip 1 header line and lines starting with '#'
for rec in eachrecord("flights.dat", schema; skip_header=1, comment=UInt8('#'))
    println(rec.carrier, rec.flight)
end
```
"""
function eachrecord(
    path::AbstractString,
    schema::FixedWidthSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    src = MmapSource(path, record_width(schema))
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return RecordIterator(src, schema, indices)
end

"""
    eachrecord(io::IO, schema::FixedWidthSchema;
               skip_header=0, skip_footer=0, comment=nothing,
               select=nothing, exclude=nothing) → RecordIterator

Return a lazy iterator over every record read from the IO stream `io`.

The entire stream is read into memory immediately. This overload supports
non-seekable sources such as pipes, `IOBuffer`, and `stdin`. Use the
`eachrecord(path, schema)` overload for file-backed access with memory mapping.

# Keyword Arguments
- `skip_header=0`   — skip the first N records (e.g. column headers)
- `skip_footer=0`   — skip the last N records (e.g. summary/trailer lines)
- `comment=nothing` — a `UInt8` byte; skip records whose first byte matches
                       (e.g. `comment=UInt8('#')` to skip comment lines).
                       Comment records must occupy the same fixed width as data records.
- `select=nothing`  — `Vector{Symbol}` of columns to include (others become `FWSkip`)
- `exclude=nothing` — `Vector{Symbol}` of columns to exclude (mutually exclusive with `select`)

# Example

```julia
schema = FixedWidthSchema(:val => (4, FWString()))
io = IOBuffer("AAAA\\nBBBB\\n")
for rec in eachrecord(io, schema)
    println(rec.val)
end

# Skip header and comment lines
io = IOBuffer("HDR \\n# cm\\nAAAA\\nBBBB\\n")
for rec in eachrecord(io, schema; skip_header=1, comment=UInt8('#'))
    println(rec.val)
end
```
"""
function eachrecord(
    io::IO,
    schema::FixedWidthSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    src = ChunkedSource(io, record_width(schema))
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return RecordIterator(src, schema, indices)
end

# ---------------------------------------------------------------------------
# Base iteration interface
# ---------------------------------------------------------------------------

"""
    length(iter::RecordIterator) → Int

Return the total number of records available in the iterator.
This is O(1) — returns the number of valid records (respecting any skip/comment filtering).
"""
function Base.length(iter::RecordIterator)
    iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
end

"""
    eltype(::RecordIterator) → Type

`RecordIterator` yields `NamedTuple` values.
"""
Base.eltype(::Type{<:RecordIterator}) = NamedTuple

"""
    IteratorSize(::Type{<:RecordIterator})

Declare that `RecordIterator` has a known, finite `length`.
"""
Base.IteratorSize(::Type{<:RecordIterator}) = Base.HasLength()

"""
    close(iter::RecordIterator)

Release the memory-mapped buffer and the underlying file handle.
"""
Base.close(iter::RecordIterator) = close(iter.source)

"""
    iterate(iter::RecordIterator[, state]) → (record, next_state) | nothing

Advance the iterator by one record. `state` is the 1-based record index of
the next record to parse (defaults to 1 on the first call).

Returns `nothing` when all records have been consumed.
"""
function Base.iterate(iter::RecordIterator, state::Int=1)
    n = iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
    state > n && return nothing
    src_i = iter.indices === nothing ? state : iter.indices[state]
    pos = record_offset(iter.source, src_i)
    record = parse_record(iter.schema, buffer(iter.source), pos)
    return (record, state + 1)
end

# ---------------------------------------------------------------------------
# Tables.jl interface
# ---------------------------------------------------------------------------

using Tables

"""
    Tables.istable(::Type{<:RecordIterator}) → true

Declare that `RecordIterator` satisfies the Tables.jl interface.
"""
Tables.istable(::Type{<:RecordIterator}) = true

"""
    Tables.rowaccess(::Type{<:RecordIterator}) → true

Declare that `RecordIterator` provides row-based access. Each row is a
`NamedTuple` produced lazily as the iterator advances.
"""
Tables.rowaccess(::Type{<:RecordIterator}) = true

"""
    Tables.rows(iter::RecordIterator) → RecordIterator

Return the iterator itself as the row source. `RecordIterator` already
implements the Base iteration protocol, so no wrapping is needed.
"""
Tables.rows(iter::RecordIterator) = iter
