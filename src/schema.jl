"""
    schema.jl — Runtime schema for fixed-width records.

A `FixedWidthSchema` holds an ordered list of `FieldSpec` values, one per
column.  It pre-computes 1-based byte offsets so the parser never needs to
walk the field list to locate a column.
"""

# ---------------------------------------------------------------------------
# FieldSpec
# ---------------------------------------------------------------------------

"""
    FieldSpec

Specification for a single field in a fixed-width record.

# Fields
- `name::Symbol`  — column identifier
- `width::Int`    — number of bytes occupied by the field
- `type`          — field-type descriptor (e.g. `FWString()`, `FWInt()`, `FWSkip()`)
- `offset::Int`   — 1-based byte offset of the field within a record
"""
struct FieldSpec
    name::Symbol
    width::Int
    type::Any  # FWString, FWInt, FWFloat, FWDate, FWSkip, FWFixedPoint, or custom
    offset::Int  # 1-based byte offset within record
end

"""
    FieldSpec(name, width, type)

Convenience constructor that sets `offset` to `0`.  The canonical offset is
assigned by `FixedWidthSchema` during schema construction.
"""
FieldSpec(name::Symbol, width::Int, type) = FieldSpec(name, width, type, 0)

# ---------------------------------------------------------------------------
# FixedWidthSchema
# ---------------------------------------------------------------------------

"""
    FixedWidthSchema(pairs...)

Runtime-defined schema for fixed-width records.  Each positional argument must
be a `Pair{Symbol}` mapping a column name to a `(width, descriptor)` tuple.

Pre-computes 1-based byte offsets for every field so that parsing is O(1) per
column.

# Example

```julia
schema = FixedWidthSchema(
    :carrier    => (2, FWString()),
    :flight_num => (4, FWInt()),
    :_pad       => (1, FWSkip()),
    :origin     => (3, FWString()),
)

record_width(schema)   # 10
field_names(schema)    # (:carrier, :flight_num, :_pad, :origin)
field_offsets(schema)  # (1, 3, 7, 8)
```

```jldoctest
julia> schema = FixedWidthSchema(:carrier => (2, FWString()), :fnum => (4, FWInt()));

julia> FixedWidthParsers.field_names(schema)
(:carrier, :fnum)

julia> FixedWidthParsers.record_width(schema)
6
```
"""
struct FixedWidthSchema
    fields::Vector{FieldSpec}
    record_width::Int
    offsets::Vector{Int}
    _output_fields::Vector{FieldSpec}   # non-skip fields (cached)
    _output_names::Tuple                # Tuple of Symbol names for non-skip fields

    function FixedWidthSchema(fields::Vector{FieldSpec}, rw::Int)
        offsets = [f.offset for f in fields]
        out_fields = [f for f in fields if !(f.type isa FWSkip)]
        out_names = Tuple(f.name for f in out_fields)
        return new(fields, rw, offsets, out_fields, out_names)
    end
end

"""
    _build_from_ranges(pairs, record_width) → FixedWidthSchema

Internal helper.  Build a `FixedWidthSchema` from `(name => (range, type))`
pairs.  Pairs are sorted by start byte; gaps are filled with auto-named
`FWSkip` fields; overlapping ranges throw `ArgumentError`.
"""
function _build_from_ranges(pairs, record_width::Union{Int,Nothing})
    sorted = sort(collect(pairs); by=p -> first(p.second[1]))

    fields = FieldSpec[]
    cursor = 1

    for (name, (range, type)) in sorted
        start = first(range)
        stop = last(range)
        width = stop - start + 1

        if start < cursor
            prev = fields[end]
            prev_end = prev.offset + prev.width - 1
            overlap_start = max(start, prev.offset)
            overlap_end = min(stop, prev_end)
            throw(
                ArgumentError(
                    "fields :$(prev.name) and :$name overlap at bytes $overlap_start-$overlap_end",
                ),
            )
        end

        if start > cursor
            gap_width = start - cursor
            gap_name = Symbol("_skip_$(cursor)_$(start - 1)")
            push!(fields, FieldSpec(gap_name, gap_width, FWSkip(), cursor))
        end

        push!(fields, FieldSpec(name, width, type, start))
        cursor = stop + 1
    end

    natural_width = cursor - 1
    if record_width !== nothing
        if record_width < natural_width
            throw(
                ArgumentError(
                    "record_width=$record_width is less than the end of the last field ($natural_width)",
                ),
            )
        end
        if record_width > natural_width
            gap_width = record_width - natural_width
            gap_name = Symbol("_skip_$(cursor)_$(record_width)")
            push!(fields, FieldSpec(gap_name, gap_width, FWSkip(), cursor))
        end
        rw = record_width
    else
        rw = natural_width
    end

    return FixedWidthSchema(fields, rw)
end

"""
    FixedWidthSchema(pairs...; record_width=nothing)

Construct a `FixedWidthSchema` from `Pair{Symbol}` arguments.  Three value
formats are supported, detected at runtime from the first pair's value type:

1. **Width mode** (original): `name => (width::Int, descriptor)`
   Fields are laid out consecutively starting at byte 1.

2. **Range mode**: `name => (start:stop, descriptor)`
   Fields are placed at the specified byte ranges.  Gaps are auto-filled with
   `FWSkip`.  Fields need not be given in order.  `record_width` may be
   supplied to extend the schema beyond the last field.

3. **Start+width mode**: `name => (start::Int, width::Int, descriptor)`
   Equivalent to range mode with `start:start+width-1`.

# Examples

```julia
# Width mode
FixedWidthSchema(:a => (2, FWString()), :b => (4, FWInt()))

# Range mode
FixedWidthSchema(:a => (1:2, FWString()), :b => (3:6, FWInt()))

# Start+width mode
FixedWidthSchema(:a => (1, 2, FWString()), :b => (3, 4, FWInt()))
```
"""
function FixedWidthSchema(raw_pairs::Pair...; record_width::Union{Int,Nothing}=nothing)
    # Normalize keys to Symbol
    pairs = map(raw_pairs) do p
        key = p.first
        if key isa Symbol
            key
        elseif key isa AbstractString
            Symbol(key)
        else
            throw(ArgumentError(
                "field name must be a Symbol or String, got $(typeof(key)): $(repr(key))"
            ))
        end => p.second
    end
    isempty(pairs) && return FixedWidthSchema(FieldSpec[], 0)

    first_val = pairs[1].second
    if first_val isa Tuple{UnitRange{Int},Any}
        # Range mode — validate all pairs use (range, type)
        for p in pairs
            p.second isa Tuple{UnitRange{Int},Any} || throw(
                ArgumentError(
                    "cannot mix constructor modes: first pair uses (range, type) but " *
                    ":$(p.first) uses $(typeof(p.second))",
                ),
            )
        end
        _build_from_ranges(pairs, record_width)
    elseif first_val isa Tuple{Int,Int,Any}
        # Start+width mode — convert to ranges
        # Validate that every pair uses the same (start, width, type) format
        for p in pairs
            p.second isa Tuple{Int,Int,Any} || throw(
                ArgumentError(
                    "cannot mix constructor modes: first pair uses (start, width, type) but " *
                    ":$(p.first) uses $(typeof(p.second))",
                ),
            )
        end
        range_pairs = [name => (s:(s + w - 1), type) for (name, (s, w, type)) in pairs]
        _build_from_ranges(range_pairs, record_width)
    elseif first_val isa Tuple{Int,Any}
        # Width mode (original)
        record_width !== nothing && throw(
            ArgumentError(
                "record_width keyword is only supported with range-based or start+width constructors",
            ),
        )
        # Validate that every pair uses the same (width::Int, type) format
        for p in pairs
            p.second isa Tuple{Int,Any} || throw(
                ArgumentError(
                    "cannot mix constructor modes: first pair uses (width, type) but " *
                    ":$(p.first) uses $(typeof(p.second))",
                ),
            )
        end
        fields = FieldSpec[]
        offset = 1
        for (name, (width, type)) in pairs
            push!(fields, FieldSpec(name, width, type, offset))
            offset += width
        end
        FixedWidthSchema(fields, offset - 1)
    else
        throw(
            ArgumentError(
                "unsupported pair value type: $(typeof(first_val)). " *
                "Expected (width, type), (start:end, type), or (start, width, type)",
            ),
        )
    end
end

# ---------------------------------------------------------------------------
# Accessor functions
# ---------------------------------------------------------------------------

"""
    record_width(schema::FixedWidthSchema) → Int

Total number of bytes in one record (sum of all field widths).
"""
record_width(s::FixedWidthSchema) = s.record_width

"""
    n_fields(schema::FixedWidthSchema) → Int

Number of fields (including skip fields) in the schema.
"""
n_fields(s::FixedWidthSchema) = length(s.fields)

"""
    field_names(schema::FixedWidthSchema) → NTuple{N, Symbol}

Ordered tuple of all field names (including skip fields).
"""
field_names(s::FixedWidthSchema) = Tuple(f.name for f in s.fields)

"""
    field_offsets(schema::FixedWidthSchema) → NTuple{N, Int}

Ordered tuple of 1-based byte offsets, one per field.
"""
field_offsets(s::FixedWidthSchema) = Tuple(s.offsets)

"""
    field_types(schema::FixedWidthSchema) → Vector

Ordered vector of field-type descriptors, one per field.
"""
field_types(s::FixedWidthSchema) = [f.type for f in s.fields]

"""
    non_skip_indices(schema::FixedWidthSchema) → Vector{Int}

Return the 1-based indices of fields whose descriptor is not `FWSkip`.
These are the fields that produce output values during parsing.
"""
function non_skip_indices(s::FixedWidthSchema)
    return [i for (i, f) in enumerate(s.fields) if !(f.type isa FWSkip)]
end

# ---------------------------------------------------------------------------
# _apply_column_selection
# ---------------------------------------------------------------------------

"""
    _apply_column_selection(schema, select, exclude) → FixedWidthSchema

Return a new schema with column selection applied.  Excluded fields are
converted to `FWSkip`, preserving the record width and byte offsets.

- `select::Union{AbstractVector{Symbol}, Nothing}` — keep only these columns
- `exclude::Union{AbstractVector{Symbol}, Nothing}` — drop these columns
- Both `nothing` → return original schema unchanged
- Both provided → `ArgumentError`
- Unknown column name → `ArgumentError`

Only non-skip columns participate in selection/exclusion.  A field that is
already `FWSkip` cannot be selected (it is never in the output regardless)
and excluding it is a no-op.
"""
function _apply_column_selection(
    schema::FixedWidthSchema,
    select::Union{AbstractVector{Symbol}, Nothing},
    exclude::Union{AbstractVector{Symbol}, Nothing},
)
    # Fast path: no selection
    if select === nothing && exclude === nothing
        return schema
    end

    # Validate: cannot have both
    if select !== nothing && exclude !== nothing
        throw(ArgumentError("cannot specify both `select` and `exclude`"))
    end

    # Build set of all field names for validation (used by both select and exclude)
    all_names = Set(f.name for f in schema.fields)
    # Non-skip names are the only ones eligible as output columns
    non_skip_names = Set(f.name for f in schema.fields if !(f.type isa FWSkip))

    if select !== nothing
        for col in select
            if col in non_skip_names
                continue
            elseif col in all_names
                throw(ArgumentError("column :$col is a FWSkip field and cannot be selected"))
            else
                throw(ArgumentError("unknown column :$col in `select`"))
            end
        end
        keep = Set(select)
    else
        for col in exclude
            col in all_names || throw(ArgumentError("unknown column :$col in `exclude`"))
        end
        # Excluding a FWSkip field is a no-op: only non-skip names can be removed
        keep = setdiff(non_skip_names, Set(exclude))
    end

    # Build new schema: non-kept, non-skip fields are converted to FWSkip
    pairs = Pair{Symbol}[]
    for f in schema.fields
        if f.type isa FWSkip || f.name in keep
            push!(pairs, f.name => (f.width, f.type))
        else
            push!(pairs, f.name => (f.width, FWSkip()))
        end
    end

    return FixedWidthSchema(pairs...)
end

# ---------------------------------------------------------------------------
# _parse_type_string — map type name strings to FW descriptors
# ---------------------------------------------------------------------------

"""
    _parse_type_string(s::AbstractString) → descriptor

Map a type name string to a field-type descriptor instance.

Supported strings: `"String"`, `"Int"`, `"Float64"`, `"Bool"`, `"Bool(T,F)"`,
`"Skip"`, `"Date"`, `"Date(fmt)"`, `"FixedPoint(n)"`.
"""
function _parse_type_string(s::AbstractString)
    s = strip(s)
    s == "String"  && return FWString()
    s == "Int"     && return FWInt()
    s == "Float64" && return FWFloat()
    s == "Skip"    && return FWSkip()
    s == "Bool"    && return FWBool()
    s == "Date"     && return FWDate("yyyymmdd")
    s == "Time"     && return FWTime()
    s == "DateTime" && return FWDateTime()

    # DateTime(fmt)
    m = match(r"^DateTime\((.+)\)$", s)
    if m !== nothing
        return FWDateTime(strip(m.captures[1]))
    end

    # Time(fmt)
    m = match(r"^Time\((.+)\)$", s)
    if m !== nothing
        return FWTime(strip(m.captures[1]))
    end

    # Date(fmt)
    m = match(r"^Date\((.+)\)$", s)
    if m !== nothing
        return FWDate(strip(m.captures[1]))
    end

    # FixedPoint(n)
    m = match(r"^FixedPoint\((\d+)\)$", s)
    if m !== nothing
        return FWFixedPoint(parse(Int, m.captures[1]))
    end

    # Bool(T,F)
    m = match(r"^Bool\(([^,]+),([^)]+)\)$", s)
    if m !== nothing
        return FWBool(true_val = strip(m.captures[1]), false_val = strip(m.captures[2]))
    end

    throw(ArgumentError("unknown type string \"$s\""))
end

"""
    _parse_type_string(type_str, format_str) → descriptor

Map a type name string to a field-type descriptor, optionally overriding the
format with `format_str`. The format column takes precedence over any inline
format in the type string (e.g., `Date(yyyymmdd)`).
"""
function _parse_type_string(type_str::AbstractString, format_str::AbstractString)
    type_str = strip(type_str)
    format_str = strip(format_str)

    # If no format override, delegate to existing single-arg form
    isempty(format_str) && return _parse_type_string(type_str)

    # Extract base type name (strip parenthesized params)
    base_type = type_str
    m = match(r"^(\w+)\(", type_str)
    if m !== nothing
        base_type = m.captures[1]
    end

    # Apply format override for Date/Time/DateTime types
    if base_type == "Date"
        return FWDate(format_str)
    elseif base_type == "Time"
        return FWTime(format_str)
    elseif base_type == "DateTime"
        return FWDateTime(format_str)
    end

    # For non-date types, ignore format_str and delegate
    return _parse_type_string(type_str)
end

# ---------------------------------------------------------------------------
# schema() generic — overridden per-type by @fixedwidth
# ---------------------------------------------------------------------------

"""
    schema(::Type{T}) → FixedWidthSchema

Return the `FixedWidthSchema` associated with a type `T` generated by the
`@fixedwidth` macro.  A method is emitted for each struct decorated with
`@fixedwidth`.  Calling `schema` on a type without an `@fixedwidth` definition
throws an `ArgumentError`.
"""
function schema end

schema(::Type{T}) where {T} =
    throw(ArgumentError("no schema defined for type $T; use @fixedwidth to define one"))

# ---------------------------------------------------------------------------
# _type_to_descriptor — compile-time Julia-type → FW descriptor mapping
# ---------------------------------------------------------------------------

"""
    _type_to_descriptor(T::Type) → FW descriptor instance

Map a Julia type, as written in a `@fixedwidth` struct field annotation, to
the appropriate `parse_field` descriptor instance.

Called at macro-expansion time to build the schema.
"""
_type_to_descriptor(::Type{String})  = FWString()
_type_to_descriptor(::Type{Int})     = FWInt()
_type_to_descriptor(::Type{Float64}) = FWFloat()
_type_to_descriptor(::Type{Date})    = FWDate("yyyymmdd")
_type_to_descriptor(::Type{Skip})    = FWSkip()
_type_to_descriptor(::Type{Bool})    = FWBool()
_type_to_descriptor(::Type{Time})     = FWTime()
_type_to_descriptor(::Type{DateTime}) = FWDateTime()

# ---------------------------------------------------------------------------
# @fixedwidth macro
# ---------------------------------------------------------------------------

"""
    @fixedwidth struct TypeName
        field1::Type1 = width1
        field2::Type2 = width2
        _skip::Skip   = width3   # skip fields: omitted from the struct
        ...
    end

Transform a struct definition into a normal Julia struct (without `Skip`
fields and without `= width` assignments) and simultaneously emit:

1. A concrete `struct TypeName` containing only the non-skip fields.
2. A `FixedWidthParsers.schema(::Type{TypeName})` method that returns the
   full `FixedWidthSchema` (including skip fields so the byte layout is
   correct).
3. Thin dispatch overloads:
   - `FixedWidthParsers.parse_file(path, ::Type{TypeName}; kw...)`
   - `FixedWidthParsers.eachrecord(path, ::Type{TypeName})`

# Example

```julia
@fixedwidth struct FlightRecord
    carrier::String = 2
    number::Int     = 4
    _pad::Skip      = 1
    origin::String  = 3
end

schema(FlightRecord)          # FixedWidthSchema with record_width 10
parse_file("flights.dat", FlightRecord)  # StructArray with :carrier, :number, :origin
```
"""
macro fixedwidth(expr)
    # Validate input — must be a struct expression
    if !(expr isa Expr && expr.head === :struct)
        error("@fixedwidth expects a struct definition")
    end

    # -----------------------------------------------------------------------
    # 1. Extract the struct name and body
    # -----------------------------------------------------------------------
    is_mutable = expr.args[1]
    type_name  = expr.args[2]  # may be a plain Symbol or Expr (e.g. T <: S)
    body       = expr.args[3]  # Expr(:block, ...)

    # Collect the raw field lines, skipping LineNumberNodes
    raw_fields = filter(x -> !(x isa LineNumberNode), body.args)

    # -----------------------------------------------------------------------
    # 2. Parse each field: name, Julia type symbol, width
    #    Expected form:  fieldname::SomeType = integer_literal
    # -----------------------------------------------------------------------
    struct_name = type_name isa Symbol ? type_name : type_name.args[1]

    parsed = []  # Vector of (name::Symbol, type_expr, width::Int, is_skip::Bool)
    for field in raw_fields
        if !(field isa Expr && field.head === :(=))
            error(
                "@fixedwidth: every field must have the form `name::Type = width`, " *
                "got: $(field)",
            )
        end
        lhs, width = field.args[1], field.args[2]
        if !(lhs isa Expr && lhs.head === :(::))
            error(
                "@fixedwidth: field LHS must be `name::Type`, got: $(lhs)",
            )
        end
        fname = lhs.args[1]
        ftype = lhs.args[2]
        # Determine at macro-expansion time whether the type resolves to Skip
        # We check the expression symbolically — the user writes Skip literally.
        is_skip = (ftype === :Skip) ||
                  (ftype isa Expr && ftype.head === :(.) && ftype.args[end] === QuoteNode(:Skip))
        push!(parsed, (fname, ftype, width, is_skip))
    end

    # -----------------------------------------------------------------------
    # 3. Build the cleaned struct (non-skip fields only, no `= width`)
    # -----------------------------------------------------------------------
    struct_fields = Expr[]
    for (fname, ftype, _width, is_skip) in parsed
        is_skip && continue
        push!(struct_fields, Expr(:(::), fname, ftype))
    end
    clean_struct = Expr(
        :struct,
        is_mutable,
        type_name,
        Expr(:block, struct_fields...),
    )

    # -----------------------------------------------------------------------
    # 4. Build the schema() method body
    #    We construct the Pair{Symbol} arguments for FixedWidthSchema at
    #    macro-expansion time so the emitted code is fully concrete.
    # -----------------------------------------------------------------------
    schema_pairs = Expr[]
    for (fname, ftype, width, is_skip) in parsed
        # Resolve the type at macro-expansion time so we can call
        # _type_to_descriptor and bake the descriptor into the quoted code.
        # We build the descriptor expression symbolically.
        descriptor_expr = if is_skip
            :(FixedWidthParsers.FWSkip())
        elseif ftype === :String
            :(FixedWidthParsers.FWString())
        elseif ftype === :Int
            :(FixedWidthParsers.FWInt())
        elseif ftype === :Float64
            :(FixedWidthParsers.FWFloat())
        elseif ftype === :Date ||
               (ftype isa Expr && ftype.head === :(.) && ftype.args[end] === QuoteNode(:Date))
            :(FixedWidthParsers.FWDate("yyyymmdd"))
        elseif ftype === :Bool
            :(FixedWidthParsers.FWBool())
        elseif ftype === :Time ||
               (ftype isa Expr && ftype.head === :(.) && ftype.args[end] === QuoteNode(:Time))
            :(FixedWidthParsers.FWTime())
        elseif ftype === :DateTime ||
               (ftype isa Expr && ftype.head === :(.) && ftype.args[end] === QuoteNode(:DateTime))
            :(FixedWidthParsers.FWDateTime())
        else
            # Generic fallback: call _type_to_descriptor at runtime
            :(FixedWidthParsers._type_to_descriptor($(esc(ftype))))
        end
        push!(
            schema_pairs,
            :($(QuoteNode(fname)) => ($width, $descriptor_expr)),
        )
    end

    schema_method = quote
        function FixedWidthParsers.schema(::Type{$(esc(struct_name))})
            return FixedWidthParsers.FixedWidthSchema($(schema_pairs...))
        end
    end

    # -----------------------------------------------------------------------
    # 5. Dispatch overloads
    # -----------------------------------------------------------------------
    dispatch_methods = quote
        function FixedWidthParsers.parse_file(
            path::AbstractString,
            ::Type{$(esc(struct_name))};
            columnar::Bool=true,
            on_error::Symbol=:strict,
            ntasks::Int=1,
            skip_header::Int=0,
            skip_footer::Int=0,
            comment::Union{UInt8, Nothing}=nothing,
            select::Union{AbstractVector{Symbol}, Nothing}=nothing,
            exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
        )
            if columnar
                return FixedWidthParsers._parse_file_generated(
                    path, $(esc(struct_name)), on_error, ntasks;
                    skip_header=skip_header, skip_footer=skip_footer, comment=comment,
                    select=select, exclude=exclude)
            else
                return FixedWidthParsers.parse_file(
                    path, FixedWidthParsers.schema($(esc(struct_name)));
                    columnar=false, on_error=on_error,
                    skip_header=skip_header, skip_footer=skip_footer, comment=comment,
                    select=select, exclude=exclude)
            end
        end

        function FixedWidthParsers.eachrecord(
            path::AbstractString,
            ::Type{$(esc(struct_name))};
            skip_header::Int=0,
            skip_footer::Int=0,
            comment::Union{UInt8, Nothing}=nothing,
            select::Union{AbstractVector{Symbol}, Nothing}=nothing,
            exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
        )
            return FixedWidthParsers.eachrecord(
                path,
                FixedWidthParsers.schema($(esc(struct_name)));
                skip_header=skip_header,
                skip_footer=skip_footer,
                comment=comment,
                select=select,
                exclude=exclude,
            )
        end
    end

    # -----------------------------------------------------------------------
    # 6. Combine everything into one quoted block
    # -----------------------------------------------------------------------
    return quote
        $(esc(clean_struct))
        $schema_method
        $dispatch_methods
    end
end

# ---------------------------------------------------------------------------
# Schema visualization
# ---------------------------------------------------------------------------

"""
    _descriptor_string(desc) → String

Format a descriptor with its non-default parameters for display.
"""
function _descriptor_string(::FWSkip)
    return "FWSkip"
end

function _descriptor_string(d::FWString)
    params = String[]
    d.pad != ' ' && push!(params, "pad='$(d.pad)'")
    d.default !== nothing && push!(params, "default=$(repr(d.default))")
    base = isempty(params) ? "FWString" : "FWString($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWInt)
    params = String[]
    d.pad != ' ' && push!(params, "pad='$(d.pad)'")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWInt" : "FWInt($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWFloat)
    params = String[]
    d.pad != ' ' && push!(params, "pad='$(d.pad)'")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWFloat" : "FWFloat($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWBool)
    params = String[]
    (d.true_val != "Y" || d.false_val != "N") && push!(params, "\"$(d.true_val)\",\"$(d.false_val)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWBool" : "FWBool($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWDate)
    params = String[]
    d.format_string != "yyyymmdd" && push!(params, "\"$(d.format_string)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWDate" : "FWDate($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWTime)
    params = String[]
    d.format_string != "HH:MM" && push!(params, "\"$(d.format_string)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWTime" : "FWTime($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWDateTime)
    params = String[]
    d.format_string != "yyyy-mm-ddTHH:MM:SS" && push!(params, "\"$(d.format_string)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWDateTime" : "FWDateTime($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWCustom)
    mode = d.raw ? "raw" : "string"
    base = "FWCustom($(d.return_type), $mode)"
    d.default !== nothing && (base *= ", default=$(repr(d.default))")
    d.transform !== nothing && (base *= "+transform")
    return base
end

function _descriptor_string(d::FWFixedPoint)
    params = ["$(d.decimals)"]
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = "FWFixedPoint($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

"""
    Base.show(io::IO, s::FixedWidthSchema)

Compact single-line display.
"""
function Base.show(io::IO, s::FixedWidthSchema)
    nout = length(s._output_fields)
    nf = length(s.fields)
    print(io, "FixedWidthSchema($(s.record_width) bytes, $nf fields, $nout output)")
end

"""
    Base.show(io::IO, ::MIME"text/plain", s::FixedWidthSchema)

Multi-line REPL display with aligned columns.
"""
function Base.show(io::IO, ::MIME"text/plain", s::FixedWidthSchema)
    nout = length(s._output_fields)
    nf = length(s.fields)
    println(io, "FixedWidthSchema ($(s.record_width) bytes, $nf fields, $nout output)")

    isempty(s.fields) && return

    # Build display rows
    rows = Tuple{String,String,String,String}[]
    for f in s.fields
        last_byte = f.offset + f.width - 1
        bytes_str = "$(f.offset):$(last_byte)"
        width_str = "$(f.width)"
        name_str = string(f.name)
        type_str = _descriptor_string(f.type)
        push!(rows, (bytes_str, width_str, name_str, type_str))
    end

    # Compute column widths
    w_bytes = max(5, maximum(length(r[1]) for r in rows))
    w_width = max(5, maximum(length(r[2]) for r in rows))
    w_name = max(4, maximum(length(r[3]) for r in rows))

    # Header
    println(io, " ", rpad("Bytes", w_bytes), "  ", rpad("Width", w_width), "  ", rpad("Name", w_name), "  Type")

    # Data rows
    for (bytes_str, width_str, name_str, type_str) in rows
        println(io, " ", lpad(bytes_str, w_bytes), "  ", lpad(width_str, w_width), "  ", rpad(name_str, w_name), "  ", type_str)
    end
end
