"""
    materialization.jl — Eager file parsing into columnar or row-oriented storage.

The primary entry point is `parse_file`, which reads an entire fixed-width file
and returns either a `StructArray` (columnar, default) or a `Vector` of
`NamedTuple`s (row-oriented).
"""

using StructArrays

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    parse_file(path, schema; columnar=true, on_error=:strict, ntasks=1,
               skip_header=0, skip_footer=0, comment=nothing,
               select=nothing, exclude=nothing) → StructArray or Vector{NamedTuple}

Parse an entire fixed-width file into memory.

# Arguments
- `path`    — path to the fixed-width file
- `schema`  — `FixedWidthSchema` describing the record layout

# Keyword Arguments
- `columnar=true`      — return a `StructArray` (column-oriented, default)
- `columnar=false`     — return a `Vector` of `NamedTuple`s (row-oriented)
- `on_error=:strict`   — throw a `ParseError` when a field cannot be parsed
- `on_error=:lenient`  — return `missing` for unparseable fields and log a warning
- `ntasks=1`           — number of tasks for parallel columnar parsing.
                         When `ntasks > 1` and `columnar=true`, each column is
                         filled in parallel over disjoint record ranges using
                         `Threads.@spawn`. Clamped to the number of records.
                         Ignored when `columnar=false`.
- `skip_header=0`      — number of leading records to skip (e.g. header lines)
- `skip_footer=0`      — number of trailing records to skip (e.g. footer/trailer lines)
- `comment=nothing`    — if a `UInt8` byte value, skip any record whose first byte
                         matches this value (e.g. `UInt8('#')` to skip comment lines).
                         Comment records must occupy the same fixed width as data records.
- `select=nothing`     — a `Vector{Symbol}` of column names to include; all others are
                         excluded (converted to `FWSkip`). Mutually exclusive with `exclude`.
- `exclude=nothing`    — a `Vector{Symbol}` of column names to exclude. Mutually exclusive
                         with `select`.

`FWSkip` fields are excluded from the output in both modes.

# Examples

```julia
schema = FixedWidthSchema(
    :carrier    => (2, FWString()),
    :flight_num => (4, FWInt()),
    :_pad       => (1, FWSkip()),
)

# Columnar (default) — each column is a contiguous Vector
sa = parse_file("flights.dat", schema)
sa.carrier     # Vector{String}
sa.flight_num  # Vector{Int}

# Row-oriented
rows = parse_file("flights.dat", schema; columnar=false)
rows[1].carrier  # "UA"

# Lenient — bad fields become missing
sa = parse_file("flights.dat", schema; on_error=:lenient)
sa.flight_num  # Vector{Union{Int, Missing}}

# Parallel columnar parsing (4 tasks)
sa = parse_file("flights.dat", schema; ntasks=4)

# Skip header and footer lines, and comment lines starting with '#'
sa = parse_file("flights.dat", schema; skip_header=1, skip_footer=1, comment=UInt8('#'))
```
"""
function parse_file(
    path::AbstractString,
    schema::FixedWidthSchema;
    columnar::Bool=true,
    on_error::Symbol=:strict,
    ntasks::Int=1,
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    src = MmapSource(path, record_width(schema))
    n = record_count(src)

    if n == 0
        close(src)
        return columnar ? _empty_structarray(schema, on_error) : NamedTuple[]
    end

    buf = buffer(src)
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)

    # Fast path: no filtering — use existing direct paths
    if indices === nothing
        result = if columnar
            _parse_columnar(schema, src, buf, n, on_error, ntasks)
        else
            _parse_rows(schema, src, buf, n, on_error)
        end
        close(src)
        return result
    end

    # Filtered path
    nvalid = length(indices)
    if nvalid == 0
        close(src)
        return columnar ? _empty_structarray(schema, on_error) : NamedTuple[]
    end

    result = if columnar
        _parse_columnar_indexed(schema, src, buf, indices, on_error, ntasks)
    else
        _parse_rows_indexed(schema, src, buf, indices, on_error)
    end
    close(src)
    return result
end

"""
    _partition_ranges(n, ntasks) → Vector{UnitRange{Int}}

Partition `1:n` into `min(n, ntasks)` contiguous ranges of roughly equal size.
"""
function _partition_ranges(n::Int, ntasks::Int)
    ntasks = min(n, ntasks)
    chunk = n ÷ ntasks
    remainder = n % ntasks
    ranges = Vector{UnitRange{Int}}(undef, ntasks)
    lo = 1
    for i in 1:ntasks
        hi = lo + chunk - 1 + (i <= remainder ? 1 : 0)
        ranges[i] = lo:hi
        lo = hi + 1
    end
    return ranges
end

"""
    _valid_record_indices(src, skip_header, skip_footer, comment) → Vector{Int} or nothing

Build a vector of valid 1-based record indices, excluding headers, footers,
and comment lines. Returns `nothing` when no filtering is needed (all three
parameters are at their defaults), signaling the caller to use the fast path.

Comment detection checks the first byte of each record slot against `comment`.
Comment lines must be the same fixed width as data records.
"""
function _valid_record_indices(
    src::AbstractSource,
    skip_header::Int,
    skip_footer::Int,
    comment::Union{UInt8, Nothing},
)
    skip_header < 0 && throw(ArgumentError("skip_header must be >= 0, got $skip_header"))
    skip_footer < 0 && throw(ArgumentError("skip_footer must be >= 0, got $skip_footer"))
    n = record_count(src)
    lo = 1 + skip_header
    hi = n - skip_footer
    if lo > hi
        return Int[]
    end

    if comment === nothing
        if lo == 1 && hi == n
            return nothing  # fast path: no filtering needed
        end
        return collect(lo:hi)
    end

    buf = buffer(src)
    indices = Int[]
    sizehint!(indices, hi - lo + 1)
    for i in lo:hi
        pos = record_offset(src, i)
        if buf[pos] != comment
            push!(indices, i)
        end
    end
    return indices
end

"""
    _rethrow_unwrapped(e)

Unwrap `CompositeException` / `TaskFailedException` wrappers that `@sync` adds
around errors thrown inside `Threads.@spawn` tasks, then rethrow the root cause.
This ensures users see a clean `ParseError` rather than a wrapped exception.
"""
function _rethrow_unwrapped(e)
    inner = e
    if inner isa CompositeException && !isempty(inner.exceptions)
        inner = first(inner.exceptions)
    end
    if inner isa TaskFailedException
        inner = inner.task.result
    end
    throw(inner)
end

# ---------------------------------------------------------------------------
# Default-value helpers
# ---------------------------------------------------------------------------

"""
    _is_blank(buf, pos, len, pad_byte) → Bool

Return true if all bytes in `buf[pos:pos+len-1]` equal `pad_byte`.
"""
@inline function _is_blank(buf::AbstractVector{UInt8}, pos::Int, len::Int, pad_byte::UInt8)
    @inbounds for i in pos:pos+len-1
        buf[i] != pad_byte && return false
    end
    return true
end

"""
    _pad_byte(descriptor) → UInt8

Return the pad byte for blank detection.
"""
_pad_byte(d::FWString) = UInt8(d.pad)
_pad_byte(d::FWInt) = UInt8(d.pad)
_pad_byte(d::FWFloat) = UInt8(d.pad)
_pad_byte(::Any) = UInt8(' ')

"""
    _get_default(descriptor) → value or nothing
"""
_get_default(d::FWString) = d.default
_get_default(d::FWInt) = d.default
_get_default(d::FWFloat) = d.default
_get_default(d::FWBool) = d.default
_get_default(d::FWDate) = d.default
_get_default(d::FWFixedPoint) = d.default
_get_default(::Any) = nothing

"""
    _get_transform(descriptor) → Function or nothing
"""
_get_transform(d::FWString) = d.transform
_get_transform(d::FWInt) = d.transform
_get_transform(d::FWFloat) = d.transform
_get_transform(d::FWBool) = d.transform
_get_transform(d::FWDate) = d.transform
_get_transform(d::FWFixedPoint) = d.transform
_get_transform(::Any) = nothing

"""Return `Any` when transform is set, else delegate to `_julia_type`."""
function _julia_type_with_transform(desc, width::Int)
    _get_transform(desc) !== nothing && return Any
    return _julia_type(desc, width)
end

"""Return true when any output field in the schema has a transform."""
_has_transforms(sch::FixedWidthSchema) =
    any(f -> _get_transform(f.type) !== nothing, sch._output_fields)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

"""
    _safe_parse_field(field, buf, rec_pos, record_idx, on_error)

Try `parse_field` for `field` at the given record position.

- In `:strict` mode: re-throws any exception as a `ParseError` with context.
- In `:lenient` mode: returns `missing` on failure and emits a `@warn`.
- In `:default` mode: if the field is blank and a default is configured,
  returns the default; if blank with no default or if parsing fails, throws
  a `ParseError`.
"""
function _safe_parse_field(
    field::FieldSpec,
    buf::AbstractVector{UInt8},
    rec_pos::Int,
    record_idx::Int,
    on_error::Symbol,
)
    field_pos = rec_pos + field.offset - 1
    col_range = field.offset:(field.offset + field.width - 1)
    xform = _get_transform(field.type)

    # :default mode: check for blank before attempting parse
    if on_error === :default
        pad = _pad_byte(field.type)
        if _is_blank(buf, field_pos, field.width, pad)
            dflt = _get_default(field.type)
            if dflt === nothing
                raw = collect(buf[field_pos:field_pos+field.width-1])
                throw(
                    ParseError(
                        record_idx,
                        col_range,
                        raw,
                        _julia_type(field.type),
                        "Blank field :$(field.name) has no default value",
                    ),
                )
            end
            # Apply _coerce then transform to default value
            if xform !== nothing
                try
                    coerced = _coerce(field.type, field.width, dflt)
                    return xform(coerced)
                catch e
                    raw = collect(buf[field_pos:field_pos+field.width-1])
                    throw(
                        ParseError(
                            record_idx,
                            col_range,
                            raw,
                            _julia_type(field.type),
                            "Failed to parse field :$(field.name): $(sprint(showerror, e))",
                        ),
                    )
                end
            end
            return dflt
        end
        # Not blank — parse normally; any parse error becomes a ParseError
        try
            val = parse_field(field.type, buf, field_pos, field.width)
            if xform !== nothing
                val = _coerce(field.type, field.width, val)
                val = xform(val)
            end
            return val
        catch e
            raw = collect(buf[field_pos:field_pos+field.width-1])
            throw(
                ParseError(
                    record_idx,
                    col_range,
                    raw,
                    _julia_type(field.type),
                    "Failed to parse field :$(field.name): $(sprint(showerror, e))",
                ),
            )
        end
    end

    try
        val = parse_field(field.type, buf, field_pos, field.width)
        if xform !== nothing
            val = _coerce(field.type, field.width, val)
            val = xform(val)
        end
        return val
    catch e
        raw = collect(buf[field_pos:field_pos+field.width-1])
        if on_error === :strict
            throw(
                ParseError(
                    record_idx,
                    col_range,
                    raw,
                    _julia_type(field.type),
                    "Failed to parse field :$(field.name): $(sprint(showerror, e))",
                ),
            )
        else  # :lenient
            @warn "Parse error at line $record_idx, field :$(field.name)" exception = e
            return missing
        end
    end
end

"""
    _parse_columnar(schema, src, buf, n, on_error, ntasks) → StructArray

Single-pass columnar parse.  Columns are pre-allocated to exact size `n` so
no `push!` or resizing occurs during the fill loop.

When `ntasks > 1`, each column is filled in parallel using `Threads.@spawn`
over disjoint record ranges produced by `_partition_ranges`.

When `on_error === :lenient` column element types are `Union{T, Missing}`.
"""
function _parse_columnar(
    schema::FixedWidthSchema,
    src::MmapSource,
    buf::AbstractVector{UInt8},
    n::Int,
    on_error::Symbol,
    ntasks::Int,
)
    ns_fields = schema._output_fields
    names = schema._output_names

    # Pre-allocate typed column vectors.
    # In lenient mode use Union{T, Missing} so that missing values fit.
    # In strict and default mode use plain Vector{T} (no Missing).
    # When a transform is set, column type is Any (output type is unknown).
    columns = if on_error === :lenient
        [Vector{Union{_julia_type_with_transform(f.type, f.width), Missing}}(undef, n) for f in ns_fields]
    else
        [Vector{_julia_type_with_transform(f.type, f.width)}(undef, n) for f in ns_fields]
    end

    ranges = _partition_ranges(n, ntasks)

    # Function-barrier fill: one call per column.  Julia specializes
    # _fill_column! on the concrete descriptor type, eliminating dynamic
    # dispatch inside the inner (per-record) loop.
    for (col_idx, f) in enumerate(ns_fields)
        if length(ranges) == 1
            _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, ranges[1], on_error)
        else
            try
                @sync for r in ranges
                    Threads.@spawn _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, r, on_error)
                end
            catch e
                _rethrow_unwrapped(e)
            end
        end
    end

    col_nt = NamedTuple{names}(Tuple(columns))
    return StructArray(col_nt)
end

"""
    _fill_column!(col, descriptor, width, offset, name, buf, src, record_range, on_error)

Fill a single pre-allocated column vector by scanning records in `record_range`.
Because `descriptor` has a concrete type at each call site, Julia compiles
a specialized version with zero dynamic dispatch in the inner loop.

In strict mode the try/catch is placed *outside* the hot loop so that no
exception-frame overhead is paid per record.  On the rare error path, the
loop is re-scanned to locate the failing record.
"""
function _fill_column!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if on_error === :strict
        _fill_column_strict!(col, descriptor, width, offset, name, buf, src, record_range)
    elseif on_error === :default
        _fill_column_default!(col, descriptor, width, offset, name, buf, src, record_range)
    else
        _fill_column_lenient!(col, descriptor, width, offset, name, buf, src, record_range)
    end
end

@inline function _fill_column_strict!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
)
    xform = _get_transform(descriptor)
    try
        @inbounds for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            val = parse_field(descriptor, buf, field_pos, width)
            val = _coerce(descriptor, width, val)
            if xform !== nothing
                val = xform(val)
            end
            col[i] = val
        end
    catch
        # Rescan to find the failing record and produce a rich ParseError
        for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            try
                val = parse_field(descriptor, buf, field_pos, width)
                val = _coerce(descriptor, width, val)
                if xform !== nothing
                    xform(val)
                end
            catch e
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(
                    ParseError(
                        i, col_range, raw, _julia_type(descriptor),
                        "Failed to parse field :$(name): $(sprint(showerror, e))",
                    ),
                )
            end
        end
    end
end

function _fill_column_lenient!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
)
    xform = _get_transform(descriptor)
    @inbounds for i in record_range
        field_pos = record_offset(src, i) + offset - 1
        try
            val = parse_field(descriptor, buf, field_pos, width)
            val = _coerce(descriptor, width, val)
            if xform !== nothing
                val = xform(val)
            end
            col[i] = val
        catch e
            @warn "Parse error at line $i, field :$(name)" exception = e
            col[i] = missing
        end
    end
end

"""
    _fill_column_default!(col, descriptor, width, offset, name, buf, src, record_range)

Fill column in `:default` mode:
- If the field is blank and a default is configured, store the default.
- If the field is blank with no default, throw a `ParseError`.
- If the field is not blank but parsing fails, throw a `ParseError`.
"""
function _fill_column_default!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
)
    pad = _pad_byte(descriptor)
    dflt = _get_default(descriptor)
    xform = _get_transform(descriptor)
    try
        @inbounds for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            if _is_blank(buf, field_pos, width, pad)
                if dflt === nothing
                    # Rescan will produce the rich error below
                    error("blank with no default")
                end
                val = _coerce(descriptor, width, dflt)
                if xform !== nothing
                    val = xform(val)
                end
                col[i] = val
            else
                val = parse_field(descriptor, buf, field_pos, width)
                val = _coerce(descriptor, width, val)
                if xform !== nothing
                    val = xform(val)
                end
                col[i] = val
            end
        end
    catch
        # Rescan to find the failing record and produce a rich ParseError
        for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            col_range = offset:(offset + width - 1)
            if _is_blank(buf, field_pos, width, pad)
                if dflt === nothing
                    raw = collect(buf[field_pos:field_pos+width-1])
                    throw(
                        ParseError(
                            i, col_range, raw, _julia_type(descriptor),
                            "Blank field :$(name) has no default value",
                        ),
                    )
                elseif xform !== nothing
                    try
                        xform(_coerce(descriptor, width, dflt))
                    catch e
                        raw = collect(buf[field_pos:field_pos+width-1])
                        throw(
                            ParseError(
                                i, col_range, raw, _julia_type(descriptor),
                                "Failed to apply transform to default for field :$(name): $(sprint(showerror, e))",
                            ),
                        )
                    end
                end
            else
                try
                    val = parse_field(descriptor, buf, field_pos, width)
                    val = _coerce(descriptor, width, val)
                    if xform !== nothing
                        xform(val)
                    end
                catch e
                    raw = collect(buf[field_pos:field_pos+width-1])
                    throw(
                        ParseError(
                            i, col_range, raw, _julia_type(descriptor),
                            "Failed to parse field :$(name): $(sprint(showerror, e))",
                        ),
                    )
                end
            end
        end
    end
end

"""
    _fill_column!(col, descriptor::FWString, ..., record_range, on_error) — zero-allocation string specialization

Constructs InlineStrings directly from buffer bytes using `Base.bitcast`,
bypassing the StringView/SubArray intermediate that would otherwise allocate
2 heap objects per string field per record.

In `:default` mode, checks for a blank field and substitutes the default value
if configured, or throws a `ParseError` if no default is set.
"""
function _fill_column!(
    col::AbstractVector,
    descriptor::FWString,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if descriptor.transform !== nothing
        # Fall back to generic path when transform is set
        if on_error === :strict
            _fill_column_strict!(col, descriptor, width, offset, name, buf, src, record_range)
        elseif on_error === :default
            _fill_column_default!(col, descriptor, width, offset, name, buf, src, record_range)
        else
            _fill_column_lenient!(col, descriptor, width, offset, name, buf, src, record_range)
        end
        return
    end
    ISType = _inline_string_type(width)
    if on_error === :default
        _fill_string_column_default!(col, ISType, descriptor, width, offset, name, buf, src, record_range)
    else
        _fill_string_column!(col, ISType, descriptor, width, offset, buf, src, record_range)
    end
end

"""Concrete-type inner loop for string column fill. `T` is the InlineString type."""
function _fill_string_column!(
    col::AbstractVector,
    ::Type{T},
    descriptor::FWString,
    width::Int,
    offset::Int,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
) where {T}
    pad_byte = UInt8(descriptor.pad)
    empty_val = T("")
    @inbounds for i in record_range
        field_pos = record_offset(src, i) + offset - 1
        # Strip trailing pad bytes (same logic as parse_field for FWString)
        last = field_pos + width - 1
        while last >= field_pos && buf[last] == pad_byte
            last -= 1
        end
        actual_len = last - field_pos + 1
        col[i] = actual_len <= 0 ? empty_val : _inline_from_buf(T, buf, field_pos, actual_len)
    end
end

"""Concrete-type inner loop for string column fill in `:default` mode."""
function _fill_string_column_default!(
    col::AbstractVector,
    ::Type{T},
    descriptor::FWString,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
) where {T}
    pad_byte = UInt8(descriptor.pad)
    dflt = descriptor.default
    @inbounds for i in record_range
        field_pos = record_offset(src, i) + offset - 1
        # Strip trailing pad bytes
        last = field_pos + width - 1
        while last >= field_pos && buf[last] == pad_byte
            last -= 1
        end
        actual_len = last - field_pos + 1
        if actual_len <= 0
            # Field is entirely padding (blank)
            if dflt === nothing
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(
                    ParseError(
                        i, col_range, raw, _julia_type(descriptor),
                        "Blank field :$(name) has no default value",
                    ),
                )
            end
            col[i] = T(dflt)
        else
            col[i] = _inline_from_buf(T, buf, field_pos, actual_len)
        end
    end
end

# ---------------------------------------------------------------------------
# Indexed variants: fill column using explicit record index vector
# ---------------------------------------------------------------------------

function _fill_column!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if on_error === :strict
        _fill_column_indexed_strict!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    elseif on_error === :default
        _fill_column_indexed_default!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    else
        _fill_column_indexed_lenient!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    end
end

@inline function _fill_column_indexed_strict!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
)
    xform = _get_transform(descriptor)
    try
        @inbounds for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            val = parse_field(descriptor, buf, field_pos, width)
            val = _coerce(descriptor, width, val)
            if xform !== nothing
                val = xform(val)
            end
            col[j] = val
        end
    catch
        for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            try
                val = parse_field(descriptor, buf, field_pos, width)
                val = _coerce(descriptor, width, val)
                if xform !== nothing
                    xform(val)
                end
            catch e
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(
                    ParseError(
                        src_i, col_range, raw, _julia_type(descriptor),
                        "Failed to parse field :$(name): $(sprint(showerror, e))",
                    ),
                )
            end
        end
    end
end

function _fill_column_indexed_lenient!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
)
    xform = _get_transform(descriptor)
    @inbounds for j in record_range
        src_i = indices[j]
        field_pos = record_offset(src, src_i) + offset - 1
        try
            val = parse_field(descriptor, buf, field_pos, width)
            val = _coerce(descriptor, width, val)
            if xform !== nothing
                val = xform(val)
            end
            col[j] = val
        catch e
            @warn "Parse error at line $src_i, field :$(name)" exception = e
            col[j] = missing
        end
    end
end

"""
    _fill_column_indexed_default!(col, descriptor, ..., indices, record_range)

Indexed fill in `:default` mode: blank fields use the descriptor's default
value; blank with no default or parse failure throws a `ParseError`.
"""
function _fill_column_indexed_default!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
)
    pad = _pad_byte(descriptor)
    dflt = _get_default(descriptor)
    xform = _get_transform(descriptor)
    try
        @inbounds for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            if _is_blank(buf, field_pos, width, pad)
                if dflt === nothing
                    error("blank with no default")
                end
                val = _coerce(descriptor, width, dflt)
                if xform !== nothing
                    val = xform(val)
                end
                col[j] = val
            else
                val = parse_field(descriptor, buf, field_pos, width)
                val = _coerce(descriptor, width, val)
                if xform !== nothing
                    val = xform(val)
                end
                col[j] = val
            end
        end
    catch
        for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            col_range = offset:(offset + width - 1)
            if _is_blank(buf, field_pos, width, pad)
                if dflt === nothing
                    raw = collect(buf[field_pos:field_pos+width-1])
                    throw(
                        ParseError(
                            src_i, col_range, raw, _julia_type(descriptor),
                            "Blank field :$(name) has no default value",
                        ),
                    )
                elseif xform !== nothing
                    try
                        xform(_coerce(descriptor, width, dflt))
                    catch e
                        raw = collect(buf[field_pos:field_pos+width-1])
                        throw(
                            ParseError(
                                src_i, col_range, raw, _julia_type(descriptor),
                                "Failed to apply transform to default for field :$(name): $(sprint(showerror, e))",
                            ),
                        )
                    end
                end
            else
                try
                    val = parse_field(descriptor, buf, field_pos, width)
                    val = _coerce(descriptor, width, val)
                    if xform !== nothing
                        xform(val)
                    end
                catch e
                    raw = collect(buf[field_pos:field_pos+width-1])
                    throw(
                        ParseError(
                            src_i, col_range, raw, _julia_type(descriptor),
                            "Failed to parse field :$(name): $(sprint(showerror, e))",
                        ),
                    )
                end
            end
        end
    end
end

# Indexed string specialization
function _fill_column!(
    col::AbstractVector,
    descriptor::FWString,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if descriptor.transform !== nothing
        # Fall back to generic indexed path when transform is set
        if on_error === :strict
            _fill_column_indexed_strict!(col, descriptor, width, offset, name, buf, src, indices, record_range)
        elseif on_error === :default
            _fill_column_indexed_default!(col, descriptor, width, offset, name, buf, src, indices, record_range)
        else
            _fill_column_indexed_lenient!(col, descriptor, width, offset, name, buf, src, indices, record_range)
        end
        return
    end
    ISType = _inline_string_type(width)
    if on_error === :default
        _fill_string_column_indexed_default!(col, ISType, descriptor, width, offset, name, buf, src, indices, record_range)
    else
        _fill_string_column_indexed!(col, ISType, descriptor, width, offset, buf, src, indices, record_range)
    end
end

function _fill_string_column_indexed!(
    col::AbstractVector,
    ::Type{T},
    descriptor::FWString,
    width::Int,
    offset::Int,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
) where {T}
    pad_byte = UInt8(descriptor.pad)
    empty_val = T("")
    @inbounds for j in record_range
        src_i = indices[j]
        field_pos = record_offset(src, src_i) + offset - 1
        last = field_pos + width - 1
        while last >= field_pos && buf[last] == pad_byte
            last -= 1
        end
        actual_len = last - field_pos + 1
        col[j] = actual_len <= 0 ? empty_val : _inline_from_buf(T, buf, field_pos, actual_len)
    end
end

"""Concrete-type indexed string column fill in `:default` mode."""
function _fill_string_column_indexed_default!(
    col::AbstractVector,
    ::Type{T},
    descriptor::FWString,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
) where {T}
    pad_byte = UInt8(descriptor.pad)
    dflt = descriptor.default
    @inbounds for j in record_range
        src_i = indices[j]
        field_pos = record_offset(src, src_i) + offset - 1
        last = field_pos + width - 1
        while last >= field_pos && buf[last] == pad_byte
            last -= 1
        end
        actual_len = last - field_pos + 1
        if actual_len <= 0
            if dflt === nothing
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(
                    ParseError(
                        src_i, col_range, raw, _julia_type(descriptor),
                        "Blank field :$(name) has no default value",
                    ),
                )
            end
            col[j] = T(dflt)
        else
            col[j] = _inline_from_buf(T, buf, field_pos, actual_len)
        end
    end
end

"""
    _parse_rows(schema, src, buf, n, on_error) → Vector{NamedTuple}

Row-oriented parse with error handling.
"""
function _parse_rows(
    schema::FixedWidthSchema,
    src::MmapSource,
    buf::AbstractVector{UInt8},
    n::Int,
    on_error::Symbol,
)
    ns_fields = schema._output_fields
    names = schema._output_names

    result = Vector{NamedTuple}(undef, n)
    for i in 1:n
        rec_pos = record_offset(src, i)
        nf = length(ns_fields)
        values = ntuple(nf) do j
            @inbounds f = ns_fields[j]
            raw = _safe_parse_field(f, buf, rec_pos, i, on_error)
            if raw === missing
                missing
            elseif _get_transform(f.type) !== nothing
                # transform already applied inside _safe_parse_field; skip _coerce
                raw
            else
                _coerce(f.type, f.width, raw)
            end
        end
        result[i] = NamedTuple{names}(values)
    end
    return result
end

"""
    _parse_columnar_indexed(schema, src, buf, indices, on_error, ntasks) → StructArray

Columnar parse using explicit record indices. Output columns have length
`length(indices)`. Supports parallel fill via `ntasks`.
"""
function _parse_columnar_indexed(
    schema::FixedWidthSchema,
    src::AbstractSource,
    buf::AbstractVector{UInt8},
    indices::Vector{Int},
    on_error::Symbol,
    ntasks::Int,
)
    ns_fields = schema._output_fields
    names = schema._output_names
    nvalid = length(indices)

    columns = if on_error === :lenient
        [Vector{Union{_julia_type_with_transform(f.type, f.width), Missing}}(undef, nvalid) for f in ns_fields]
    else
        [Vector{_julia_type_with_transform(f.type, f.width)}(undef, nvalid) for f in ns_fields]
    end

    ranges = _partition_ranges(nvalid, ntasks)

    for (col_idx, f) in enumerate(ns_fields)
        if length(ranges) == 1
            _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, indices, ranges[1], on_error)
        else
            try
                @sync for r in ranges
                    Threads.@spawn _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, indices, r, on_error)
                end
            catch e
                _rethrow_unwrapped(e)
            end
        end
    end

    col_nt = NamedTuple{names}(Tuple(columns))
    return StructArray(col_nt)
end

"""
    _parse_rows_indexed(schema, src, buf, indices, on_error) → Vector{NamedTuple}

Row-oriented parse using explicit record indices.
"""
function _parse_rows_indexed(
    schema::FixedWidthSchema,
    src::AbstractSource,
    buf::AbstractVector{UInt8},
    indices::Vector{Int},
    on_error::Symbol,
)
    ns_fields = schema._output_fields
    names = schema._output_names

    result = Vector{NamedTuple}(undef, length(indices))
    for (j, src_i) in enumerate(indices)
        rec_pos = record_offset(src, src_i)
        nf = length(ns_fields)
        values = ntuple(nf) do k
            @inbounds f = ns_fields[k]
            raw = _safe_parse_field(f, buf, rec_pos, src_i, on_error)
            if raw === missing
                missing
            elseif _get_transform(f.type) !== nothing
                # transform already applied inside _safe_parse_field; skip _coerce
                raw
            else
                _coerce(f.type, f.width, raw)
            end
        end
        result[j] = NamedTuple{names}(values)
    end
    return result
end

"""
    _empty_structarray(schema, on_error=:strict) → StructArray

Return a zero-length `StructArray` whose column types match `schema`.
When `on_error === :lenient` column element types are `Union{T, Missing}`.
"""
function _empty_structarray(schema::FixedWidthSchema, on_error::Symbol=:strict)
    ns_fields = schema._output_fields
    names = schema._output_names
    columns = if on_error === :lenient
        Tuple(Vector{Union{_julia_type_with_transform(f.type, f.width), Missing}}() for f in ns_fields)
    else
        Tuple(Vector{_julia_type_with_transform(f.type, f.width)}() for f in ns_fields)
    end
    return StructArray(NamedTuple{names}(columns))
end

# ---------------------------------------------------------------------------
# Type mapping: field descriptor → Julia element type for column storage
# ---------------------------------------------------------------------------

"""
    _julia_type(descriptor) → Type
    _julia_type(descriptor, width) → Type

Map a field-type descriptor to the concrete Julia element type used for column
pre-allocation.  For `FWString`, the width determines which `InlineString` type
is used (stack-allocated, no GC pressure for short strings).
"""
_julia_type(::FWString) = String  # fallback without width
_julia_type(::FWInt) = Int
_julia_type(::FWFloat) = Float64
_julia_type(::FWDate) = Dates.Date
_julia_type(::FWFixedPoint) = Float64
_julia_type(::FWSkip) = Nothing
_julia_type(::FWBool) = Bool
_julia_type(::Any) = Any

# Width-aware version: picks optimal InlineString type
using InlineStrings: String1, String3, String7, String15, String31
_julia_type(::FWString, width::Int) = _inline_string_type(width)
_julia_type(desc, ::Int) = _julia_type(desc)  # non-string types ignore width

"""Select the smallest InlineString type that fits `width` bytes."""
function _inline_string_type(width::Int)
    width <= 1  && return String1
    width <= 3  && return String3
    width <= 7  && return String7
    width <= 15 && return String15
    width <= 31 && return String31
    return String  # too long for inline, fall back to heap
end

# ---------------------------------------------------------------------------
# Coercion: normalize parse_field output to the column element type
# ---------------------------------------------------------------------------

"""
    _coerce(descriptor, width, value) → column-element-type value

Convert the raw value returned by `parse_field` to the concrete element type
expected by the column vector.  For `FWString`, converts to the appropriate
`InlineString` type based on field width (stack-allocated, zero GC pressure).
"""
_coerce(::FWString, width::Int, v::AbstractString) = _inline_string_type(width)(v)
_coerce(::Any, ::Int, v) = v

# ---------------------------------------------------------------------------
# Zero-allocation InlineString construction from buffer bytes
# ---------------------------------------------------------------------------

"""
    _inline_from_buf(ISType, buf, pos, len) → InlineString

Construct an `InlineString` directly from bytes `buf[pos:pos+len-1]` using
`Base.bitcast`.  Zero allocations — the entire value is built in a register.

Layout: string characters stored from MSB downward, length in LSB.
"""
@inline function _inline_from_buf(::Type{String1}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    val = UInt16(len)
    len >= 1 && (val |= UInt16(buf[pos]) << 8)
    return Base.bitcast(String1, val)
end

@inline function _inline_from_buf(::Type{String3}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    val = UInt32(len)
    @inbounds for i in 0:len-1
        val |= UInt32(buf[pos + i]) << (8 * (3 - i))
    end
    return Base.bitcast(String3, val)
end

@inline function _inline_from_buf(::Type{String7}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    val = UInt64(len)
    @inbounds for i in 0:len-1
        val |= UInt64(buf[pos + i]) << (8 * (7 - i))
    end
    return Base.bitcast(String7, val)
end

@inline function _inline_from_buf(::Type{String15}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    val = UInt128(len)
    @inbounds for i in 0:len-1
        val |= UInt128(buf[pos + i]) << (8 * (15 - i))
    end
    return Base.bitcast(String15, val)
end

@inline function _inline_from_buf(::Type{String31}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    # String31 is 256-bit; construct as two UInt128 halves
    # Layout: chars in bytes 31 down to 1, length in byte 0
    # Low 128 bits: bytes 0-15, High 128 bits: bytes 16-31
    lo = UInt128(len)
    hi = UInt128(0)
    @inbounds for i in 0:len-1
        byte_idx = 31 - i  # position in the 32-byte value (big-endian char order)
        if byte_idx >= 16
            hi |= UInt128(buf[pos + i]) << (8 * (byte_idx - 16))
        else
            lo |= UInt128(buf[pos + i]) << (8 * byte_idx)
        end
    end
    return Base.bitcast(String31, (lo, hi))
end

# Fallback for heap String (width > 31): go through unsafe_string
@inline function _inline_from_buf(::Type{String}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    return unsafe_string(pointer(buf, pos), len)
end

# ---------------------------------------------------------------------------
# Generated-path helpers
# ---------------------------------------------------------------------------

"""
    _rescan_for_error(::Type{T}, src, buf, n)

Non-generated error-locator for the strict-mode catch block of the generated
columnar path.  Iterates all output fields × all records to find the first
parse failure and throws a rich `ParseError`.
"""
function _rescan_for_error(::Type{T}, src, buf, n) where T
    sch = schema(T)
    for f in sch._output_fields
        for i in 1:n
            field_pos = record_offset(src, i) + f.offset - 1
            try
                parse_field(f.type, buf, field_pos, f.width)
            catch e
                raw = collect(buf[field_pos:field_pos+f.width-1])
                col_range = f.offset:(f.offset + f.width - 1)
                throw(ParseError(i, col_range, raw, _julia_type(f.type, f.width),
                    "Failed to parse field :$(f.name): $(sprint(showerror, e))"))
            end
        end
    end
end

"""
    _SCHEMA_CACHE :: Dict{DataType, FixedWidthSchema}

Module-level cache populated by `_parse_file_generated` before calling the
`@generated` columnar parser.  This avoids the world-age issue: `schema(T)`
is called in a regular function (latest world age), and the generator reads
from this Dict (no user-method dispatch needed).
"""
const _SCHEMA_CACHE = Dict{DataType, FixedWidthSchema}()

"""
    _parse_columnar_generated(::Type{T}, src, buf, n, ::Val{Mode})

`@generated` columnar parser.  At compile time, reads the schema for `T` from
`_SCHEMA_CACHE` and emits a single-pass loop with all field offsets, types,
and widths baked as constants.

- String fields use direct `_inline_from_buf` (zero-alloc InlineString construction)
- Non-string fields use literal `parse_field(Descriptor(), ...)` calls (no dispatch)
- `Val{:strict}` wraps the loop in a try/catch that delegates to `_rescan_for_error`
- `Val{:lenient}` wraps each field parse individually, assigning `missing` on failure
"""
@generated function _parse_columnar_generated(::Type{T}, src, buf, n, ::Val{Mode}) where {T, Mode}
    sch = _SCHEMA_CACHE[T]
    fields = sch._output_fields
    nf = length(fields)

    col_syms = [Symbol("col_", i) for i in 1:nf]
    preloop_exprs = Expr[]
    alloc_exprs = Expr[]

    # --- Column allocation and pre-loop descriptor construction ---
    for (idx, f) in enumerate(fields)
        sym = col_syms[idx]
        jtype = _julia_type(f.type, f.width)
        if Mode === :lenient
            push!(alloc_exprs, :($sym = Vector{Union{$jtype, Missing}}(undef, n)))
        else
            push!(alloc_exprs, :($sym = Vector{$jtype}(undef, n)))
        end

        # Hoist descriptor construction for types with parameters
        if f.type isa FWDate
            fmt_sym = Symbol("_datefmt_", idx)
            fmt_str = f.type.format_string
            push!(preloop_exprs, :($fmt_sym = FWDate($fmt_str)))
        elseif f.type isa FWFixedPoint
            fxp_sym = Symbol("_fxp_", idx)
            dec = f.type.decimals
            push!(preloop_exprs, :($fxp_sym = FWFixedPoint($dec)))
        end
    end

    # --- Per-field parse expressions (inside the loop) ---
    field_exprs = Expr[]
    for (idx, f) in enumerate(fields)
        sym = col_syms[idx]
        off_m1 = f.offset - 1
        w = f.width

        parse_expr = if f.type isa FWString
            ISType = _inline_string_type(w)
            pad_byte = UInt8(f.type.pad)
            quote
                let fp = rec_pos + $off_m1
                    _last = fp + $(w - 1)
                    while _last >= fp && buf[_last] == $pad_byte
                        _last -= 1
                    end
                    _alen = _last - fp + 1
                    $sym[i_rec] = _alen <= 0 ? $(ISType("")) : _inline_from_buf($ISType, buf, fp, _alen)
                end
            end
        elseif f.type isa FWInt
            if f.type.pad != ' '
                int_sym = Symbol("_int_", idx)
                push!(preloop_exprs, :($int_sym = FWInt(pad=$(f.type.pad))))
                :($sym[i_rec] = parse_field($int_sym, buf, rec_pos + $off_m1, $w))
            else
                :($sym[i_rec] = parse_field(FWInt(), buf, rec_pos + $off_m1, $w))
            end
        elseif f.type isa FWFloat
            if f.type.pad != ' '
                flt_sym = Symbol("_flt_", idx)
                push!(preloop_exprs, :($flt_sym = FWFloat(pad=$(f.type.pad))))
                :($sym[i_rec] = parse_field($flt_sym, buf, rec_pos + $off_m1, $w))
            else
                :($sym[i_rec] = parse_field(FWFloat(), buf, rec_pos + $off_m1, $w))
            end
        elseif f.type isa FWDate
            fmt_sym = Symbol("_datefmt_", idx)
            :($sym[i_rec] = parse_field($fmt_sym, buf, rec_pos + $off_m1, $w))
        elseif f.type isa FWFixedPoint
            fxp_sym = Symbol("_fxp_", idx)
            :($sym[i_rec] = parse_field($fxp_sym, buf, rec_pos + $off_m1, $w))
        elseif f.type isa FWBool
            bool_sym = Symbol("_bool_", idx)
            tv = f.type.true_val
            fv = f.type.false_val
            push!(preloop_exprs, :($bool_sym = FWBool(true_val=$tv, false_val=$fv)))
            :($sym[i_rec] = parse_field($bool_sym, buf, rec_pos + $off_m1, $w))
        else
            # Generic fallback — should not normally be reached for known types
            :($sym[i_rec] = parse_field($(f.type), buf, rec_pos + $off_m1, $w))
        end

        if Mode === :lenient
            fname = QuoteNode(f.name)
            push!(field_exprs, quote
                try
                    $parse_expr
                catch e
                    @warn string("Parse error at line ", i_rec, ", field :", $fname) exception = e
                    $sym[i_rec] = missing
                end
            end)
        else
            push!(field_exprs, parse_expr)
        end
    end

    # --- Build the loop ---
    loop_body = Expr(:block, field_exprs...)
    loop_expr = quote
        @inbounds for i_rec in 1:n
            rec_pos = record_offset(src, i_rec)
            $loop_body
        end
    end

    if Mode === :strict
        loop_expr = quote
            try
                $loop_expr
            catch
                _rescan_for_error(T, src, buf, n)
            end
        end
    end

    # --- Build result ---
    names_tuple = Tuple(f.name for f in fields)
    col_tuple = Expr(:tuple, col_syms...)

    return quote
        $(alloc_exprs...)
        $(preloop_exprs...)
        $loop_expr
        return StructArray(NamedTuple{$names_tuple}($col_tuple))
    end
end

"""
    _parse_file_generated(path, ::Type{T}, on_error, ntasks;
                          skip_header=0, skip_footer=0, comment=nothing,
                          select=nothing, exclude=nothing) → StructArray

Thin wrapper that opens an `MmapSource`, handles the empty-file edge case,
and delegates to `_parse_columnar_generated` for the actual parsing.

When `skip_header`, `skip_footer`, or `comment` filtering is requested,
calls `_valid_record_indices` and routes to `_parse_columnar_indexed`.

When `ntasks > 1` without filtering, falls back to the runtime threaded
`_parse_columnar` path because the `@generated` single-pass loop interleaves
all fields and cannot easily be partitioned across tasks.

When `select` or `exclude` is active, the `@generated` fast path is bypassed
and parsing routes through the runtime `_parse_columnar_indexed` path instead,
because the generated code is specialized for the full schema type `T`.

Populates `_SCHEMA_CACHE[T]` before invoking the `@generated` function so
that the generator body can read the schema without world-age issues.
"""
function _parse_file_generated(
    path::AbstractString, ::Type{T}, on_error::Symbol, ntasks::Int;
    skip_header::Int=0, skip_footer::Int=0, comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
    ) where {T <: Any}
    sch = schema(T)
    has_selection = select !== nothing || exclude !== nothing
    if has_selection
        sch = _apply_column_selection(sch, select, exclude)
    else
        _SCHEMA_CACHE[T] = sch
    end
    src = MmapSource(path, record_width(sch))
    n = record_count(src)
    if n == 0
        close(src)
        return _empty_structarray(sch, on_error)
    end
    buf = buffer(src)

    indices = _valid_record_indices(src, skip_header, skip_footer, comment)

    result = if indices === nothing && ntasks <= 1 && !has_selection && on_error !== :default && !_has_transforms(sch)
        # Fast generated path: no filtering, no parallelism, no column selection, no default mode, no transforms
        _parse_columnar_generated(T, src, buf, n, Val(on_error))
    elseif indices === nothing
        # No filtering: parallel path or column-selection fallback
        _parse_columnar(sch, src, buf, n, on_error, ntasks)
    else
        # Filtered path (with or without parallelism)
        nvalid = length(indices)
        if nvalid == 0
            close(src)
            return _empty_structarray(sch, on_error)
        end
        _parse_columnar_indexed(sch, src, buf, indices, on_error, ntasks)
    end
    close(src)
    return result
end
