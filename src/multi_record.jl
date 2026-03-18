"""
    multi_record.jl — Multi-record type schema for files with mixed record formats.
"""

# ---------------------------------------------------------------------------
# MultiRecordSchema
# ---------------------------------------------------------------------------

"""
    MultiRecordSchema

Schema for files with multiple record types identified by a discriminator field.

Each record type maps a discriminator value (e.g. `"H"`, `"D"`, `"T"`) to a
`FixedWidthSchema`. The discriminator byte range is checked for every record
to classify it into the appropriate group.

# Fields
- `discriminator::UnitRange{Int}` — byte range of the discriminator field
- `schemas::Vector{Tuple{String, Symbol, FixedWidthSchema}}` — `(disc_value, label, schema)` triples
- `record_width::Int` — total bytes per record (max of all schemas or override)

# Example

```julia
header_schema = FixedWidthSchema(:rec_type => (1, FWString()), :title => (9, FWString()))
detail_schema = FixedWidthSchema(:rec_type => (1, FWString()), :code  => (3, FWString()), :value => (6, FWInt()))

ms = MultiRecordSchema(
    1:1,
    "H" => header_schema,
    "D" => detail_schema,
)

result = parse_file("data.dat", ms)
result[:H].title   # Vector of header titles
result[:D].value   # Vector of detail values
```
"""
struct MultiRecordSchema
    discriminator::UnitRange{Int}
    schemas::Vector{Tuple{String, Symbol, FixedWidthSchema}}
    record_width::Int
end

# --- Label derivation helpers ---

_discriminator_label(key::AbstractString) = Symbol(key)
_discriminator_label(key::Char) = isdigit(key) ? Symbol("type_", key) : Symbol(key)
_discriminator_label(key::Int) = Symbol("type_", key)

# --- Shared builder ---

function _build_multi_record_schema(
    discriminator::UnitRange{Int},
    string_pairs::Vector{Pair{String, FixedWidthSchema}},
    labels::Vector{Symbol},
    record_width::Union{Int, Nothing},
)
    length(discriminator) < 1 &&
        throw(ArgumentError("discriminator range must not be empty"))
    isempty(string_pairs) &&
        throw(ArgumentError("at least one discriminator => schema pair is required"))

    # Trim keys unconditionally (matches trimming on the file-read side)
    trimmed_pairs = [strip(k) => v for (k, v) in string_pairs]

    vals = [p.first for p in trimmed_pairs]
    length(unique(vals)) != length(vals) &&
        throw(ArgumentError("duplicate discriminator values: $(vals)"))

    schemas = Tuple{String, Symbol, FixedWidthSchema}[]
    max_width = 0
    for (i, (disc_val, sch)) in enumerate(trimmed_pairs)
        push!(schemas, (disc_val, labels[i], sch))
        max_width = max(max_width, FixedWidthParsers.record_width(sch))
    end

    rw = record_width !== nothing ? record_width : max_width
    if rw < max_width
        throw(ArgumentError("record_width=$rw is less than the widest schema ($max_width)"))
    end

    return MultiRecordSchema(discriminator, schemas, rw)
end

"""
    MultiRecordSchema(discriminator, pairs...; record_width=nothing)

Construct a `MultiRecordSchema` from a discriminator byte range and one or more
`value => schema` pairs.

Labels are derived from discriminator values: `"H"` → `:H`, `"DT"` → `:DT`.

# Arguments
- `discriminator::UnitRange{Int}` — byte range (1-based) of the discriminator field
- `pairs...` — `Pair{String, FixedWidthSchema}` mapping each discriminator value to its schema

# Keyword Arguments
- `record_width::Union{Int, Nothing}=nothing` — override the record width (must be >= the
  widest sub-schema). Defaults to the maximum width across all sub-schemas.

# Errors
- `ArgumentError` if `discriminator` is empty
- `ArgumentError` if no pairs are supplied
- `ArgumentError` if duplicate discriminator values are supplied
- `ArgumentError` if `record_width` is less than the widest sub-schema

# Example

```julia
ms = MultiRecordSchema(
    1:1,
    "H" => header_schema,
    "D" => detail_schema,
    "T" => trailer_schema,
)
```
"""
function MultiRecordSchema(
    discriminator::UnitRange{Int};
    record_width::Union{Int, Nothing}=nothing,
)
    throw(ArgumentError("at least one discriminator => schema pair is required"))
end

function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{String, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    string_pairs = Pair{String, FixedWidthSchema}[k => v for (k, v) in pairs]
    labels = [_discriminator_label(strip(k)) for (k, _) in pairs]
    _build_multi_record_schema(discriminator, string_pairs, labels, record_width)
end

function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{Char, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    length(discriminator) != 1 &&
        throw(ArgumentError("Char discriminator keys require a single-byte range, got $discriminator"))
    string_pairs = Pair{String, FixedWidthSchema}[string(k) => v for (k, v) in pairs]
    labels = [_discriminator_label(k) for (k, _) in pairs]
    _build_multi_record_schema(discriminator, string_pairs, labels, record_width)
end

function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{Int, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    string_pairs = Pair{String, FixedWidthSchema}[string(k) => v for (k, v) in pairs]
    labels = [_discriminator_label(k) for (k, _) in pairs]
    _build_multi_record_schema(discriminator, string_pairs, labels, record_width)
end

function MultiRecordSchema(
    position::Int;
    record_width::Union{Int, Nothing}=nothing,
)
    throw(ArgumentError("at least one discriminator => schema pair is required"))
end

function MultiRecordSchema(
    position::Int,
    pairs::Pair{Char, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    return MultiRecordSchema(position:position, pairs...; record_width=record_width)
end

function MultiRecordSchema(
    position::Int,
    pairs::Pair{Int, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    return MultiRecordSchema(position:position, pairs...; record_width=record_width)
end

function MultiRecordSchema(
    position::Int,
    pairs::Pair{String, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    return MultiRecordSchema(position:position, pairs...; record_width=record_width)
end

# Catch-all: accept mixed or arbitrary key types and convert to String
function MultiRecordSchema(
    discriminator::Union{UnitRange{Int}, Int},
    pairs::Pair{<:Any, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    disc_range = discriminator isa Int ? (discriminator:discriminator) : discriminator
    string_pairs = Pair{String, FixedWidthSchema}[string(k) => v for (k, v) in pairs]
    labels = [_discriminator_label(k) for (k, _) in pairs]
    _build_multi_record_schema(disc_range, string_pairs, labels, record_width)
end

# ---------------------------------------------------------------------------
# parse_file for MultiRecordSchema
# ---------------------------------------------------------------------------

"""
    parse_file(path, ms::MultiRecordSchema; on_error=:strict, ntasks=1,
               skip_header=0, skip_footer=0, comment=nothing) → Dict{Symbol, StructArray}

Parse a multi-record file into a `Dict` mapping each record type label to its
`StructArray`.

Records are classified by reading the discriminator byte range on each line.
Unrecognised discriminator values throw an `ArgumentError`.

# Arguments
- `path` — path to the fixed-width file
- `ms`   — `MultiRecordSchema` describing the record types

# Keyword Arguments
- `on_error=:strict`   — throw a `ParseError` when a field cannot be parsed
- `on_error=:lenient`  — return `missing` for unparseable fields and log a warning
- `ntasks=1`           — number of tasks for parallel columnar parsing per group
- `skip_header=0`      — number of leading records to skip
- `skip_footer=0`      — number of trailing records to skip
- `comment=nothing`    — `UInt8` byte; skip records whose first byte matches

# Example

```julia
result = parse_file("mixed.dat", ms)
result[:H]   # StructArray of header records
result[:D]   # StructArray of detail records
result[:T]   # StructArray of trailer records
```
"""
function parse_file(
    path::AbstractString,
    ms::MultiRecordSchema;
    on_error::Symbol=:strict,
    ntasks::Int=1,
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
)
    src = MmapSource(path, ms.record_width)
    try
        n = record_count(src)
        buf = buffer(src)

        # Get valid indices (respecting skip_header, skip_footer, comment)
        raw_indices = _valid_record_indices(src, skip_header, skip_footer, comment)
        valid_indices = raw_indices === nothing ? collect(1:n) : raw_indices

        if isempty(valid_indices)
            result = Dict{Symbol, StructArray}()
            for (_, label, sch) in ms.schemas
                result[label] = _empty_structarray(sch, on_error)
            end
            return result
        end

        # Build lookup: disc_value → index into ms.schemas
        disc_lookup = Dict{String, Int}()
        for (idx, (disc_val, _, _)) in enumerate(ms.schemas)
            disc_lookup[disc_val] = idx
        end

        disc_offset = first(ms.discriminator)  # 1-based offset within record
        disc_len = length(ms.discriminator)

        # First pass: classify records by discriminator
        groups = [Int[] for _ in ms.schemas]

        for rec_idx in valid_indices
            rec_pos = record_offset(src, rec_idx)
            field_pos = rec_pos + disc_offset - 1
            disc_bytes = strip(String(copy(buf[field_pos:(field_pos + disc_len - 1)])))
            group_idx = get(disc_lookup, disc_bytes, 0)
            if group_idx == 0
                expected = join([repr(dv) for (dv, _, _) in ms.schemas], ", ")
                throw(
                    ArgumentError(
                        "unknown discriminator value $(repr(disc_bytes)) at record $rec_idx; expected one of: $expected",
                    ),
                )
            end
            push!(groups[group_idx], rec_idx)
        end

        # Second pass: parse each group with its schema
        result = Dict{Symbol, StructArray}()
        for (group_idx, (_, label, sch)) in enumerate(ms.schemas)
            group_indices = groups[group_idx]
            if isempty(group_indices)
                result[label] = _empty_structarray(sch, on_error)
            else
                result[label] = _parse_columnar_indexed(sch, src, buf, group_indices, on_error, ntasks)
            end
        end

        return result
    finally
        close(src)
    end
end

# ---------------------------------------------------------------------------
# MultiRecordIterator — lazy iteration
# ---------------------------------------------------------------------------

"""
    MultiRecordIterator

Lazy iterator over multi-record files. Each yielded `NamedTuple` includes
a `:_type::Symbol` field identifying which schema matched, followed by all
non-skip fields of that schema.

Obtain one via `eachrecord(path, ms::MultiRecordSchema; ...)`.
"""
struct MultiRecordIterator
    source::AbstractSource
    ms::MultiRecordSchema
    indices::Union{Vector{Int}, Nothing}
end

"""
    eachrecord(path, ms::MultiRecordSchema; skip_header=0, skip_footer=0,
               comment=nothing) → MultiRecordIterator

Return a lazy iterator over every record in a multi-record file.

Each element is a `NamedTuple` containing a `:_type::Symbol` field (the label
for the matched sub-schema) followed by the parsed fields of that sub-schema.

Call `close(iter)` to release the mmap when done, or use `collect` to consume
all records and let GC finalize.

# Keyword Arguments
- `skip_header=0`   — skip the first N records
- `skip_footer=0`   — skip the last N records
- `comment=nothing` — `UInt8` byte; skip records whose first byte matches

# Example

```julia
ms = MultiRecordSchema(1:1, "H" => hschema, "D" => dschema)
for rec in eachrecord("data.dat", ms)
    if rec._type === :H
        println("header: ", rec.title)
    else
        println("detail: ", rec.value)
    end
end
```
"""
function eachrecord(
    path::AbstractString,
    ms::MultiRecordSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
)
    src = MmapSource(path, ms.record_width)
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return MultiRecordIterator(src, ms, indices)
end

"""
    length(iter::MultiRecordIterator) → Int

Return the total number of valid records in the iterator (O(1)).
"""
function Base.length(iter::MultiRecordIterator)
    iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
end

"""
    eltype(::Type{<:MultiRecordIterator}) → NamedTuple
"""
Base.eltype(::Type{<:MultiRecordIterator}) = NamedTuple

"""
    IteratorSize(::Type{<:MultiRecordIterator})

Declare that `MultiRecordIterator` has a known, finite length.
"""
Base.IteratorSize(::Type{<:MultiRecordIterator}) = Base.HasLength()

"""
    close(iter::MultiRecordIterator)

Release the memory-mapped buffer and underlying file handle.
"""
Base.close(iter::MultiRecordIterator) = close(iter.source)

"""
    iterate(iter::MultiRecordIterator[, state]) → (record, next_state) | nothing

Advance the iterator by one record. `state` is the 1-based position within the
valid-index list (defaults to 1 on the first call).

Each returned record is a `NamedTuple` with a `:_type` field prepended to the
fields of the matched sub-schema.
"""
function Base.iterate(iter::MultiRecordIterator, state::Int=1)
    n = iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
    state > n && return nothing

    src_i = iter.indices === nothing ? state : iter.indices[state]
    buf = buffer(iter.source)
    rec_pos = record_offset(iter.source, src_i)

    # Read discriminator
    disc_offset = first(iter.ms.discriminator)
    disc_len = length(iter.ms.discriminator)
    field_pos = rec_pos + disc_offset - 1
    disc_bytes = strip(String(copy(buf[field_pos:(field_pos + disc_len - 1)])))

    # Find matching schema
    for (disc_val, label, sch) in iter.ms.schemas
        if disc_bytes == disc_val
            record = parse_record(sch, buf, rec_pos)
            merged = merge((_type=label,), record)
            return (merged, state + 1)
        end
    end

    expected = join([repr(dv) for (dv, _, _) in iter.ms.schemas], ", ")
    throw(
        ArgumentError(
            "unknown discriminator value $(repr(disc_bytes)) at record $src_i; expected one of: $expected",
        ),
    )
end
