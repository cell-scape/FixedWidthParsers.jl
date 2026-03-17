"""
    schema_io.jl — Load FixedWidthSchema definitions from CSV, TOML, and JSON files.
"""

import TOML

"""
    load_schema(path::AbstractString; record_width=nothing) → FixedWidthSchema

Load a schema definition from a file. The file format is determined by
the file extension:

- `.csv` — comma-separated with `name,start,end,type` columns
- `.toml` — TOML with `[[fields]]` array of tables
- `.json` — JSON with `{"fields": [...]}` (requires `using JSON3`)

# Keyword Arguments
- `record_width=nothing` — optional total record width; if provided,
  trailing bytes are filled with `FWSkip`

# Examples

```julia
schema = load_schema("flights.csv")
schema = load_schema("flights.toml")
schema = load_schema("flights.json")  # requires JSON3
```
"""
function load_schema(path::AbstractString; record_width::Union{Int,Nothing}=nothing)
    ext = lowercase(splitext(path)[2])
    if ext == ".csv"
        return _load_schema_csv(path; record_width=record_width)
    elseif ext == ".toml"
        return _load_schema_toml(path; record_width=record_width)
    elseif ext == ".json"
        try
            return _load_schema_json(path; record_width=record_width)
        catch e
            if e isa MethodError
                throw(ArgumentError(
                    "JSON schema loading requires JSON3.jl. Run `using JSON3` before calling load_schema.",
                ))
            end
            rethrow(e)
        end
    else
        throw(ArgumentError("unsupported schema file extension: $ext"))
    end
end

# --- CSV ---

function _load_schema_csv(path::AbstractString; record_width::Union{Int,Nothing}=nothing)
    lines = readlines(path)

    # Filter out blank lines and comments
    lines = filter(l -> !isempty(strip(l)) && !startswith(strip(l), '#'), lines)
    isempty(lines) && throw(ArgumentError("schema CSV file is empty"))

    # Parse header
    header = Symbol.(strip.(split(lines[1], ',')))
    required = [:name, :start, :end, :type]
    for col in required
        col in header || throw(ArgumentError("schema CSV missing required column: $col"))
    end

    # Column indices
    idx = Dict(col => findfirst(==(col), header) for col in required)
    has_format = :format in header
    if has_format
        idx[:format] = findfirst(==(:format), header)
    end

    # Parse data rows
    pairs = Pair{Symbol,Tuple{UnitRange{Int},Any}}[]
    for line in lines[2:end]
        parts = strip.(split(line, ','))
        name = Symbol(parts[idx[:name]])
        start_byte = parse(Int, parts[idx[:start]])
        end_byte = parse(Int, parts[idx[:end]])

        if has_format && idx[:format] <= length(parts)
            format_str = parts[idx[:format]]
            type_desc = _parse_type_string(parts[idx[:type]], format_str)
        else
            type_desc = _parse_type_string(parts[idx[:type]])
        end

        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthSchema(pairs...; record_width=record_width)
end

# --- TOML ---

function _load_schema_toml(path::AbstractString; record_width::Union{Int,Nothing}=nothing)
    data = TOML.parsefile(path)
    haskey(data, "fields") || throw(ArgumentError("TOML schema file missing [fields] section"))
    field_defs = data["fields"]
    field_defs isa Vector || throw(ArgumentError(
        "TOML 'fields' must be an array of tables ([[fields]])"
    ))

    pairs = Pair{Symbol,Tuple{UnitRange{Int},Any}}[]
    for (i, fd) in enumerate(field_defs)
        for key in ("name", "start", "end", "type")
            haskey(fd, key) || throw(
                ArgumentError("TOML field entry $i missing required key: $key"),
            )
        end
        name = Symbol(fd["name"])
        start_byte = fd["start"]::Int
        end_byte = fd["end"]::Int
        format_str = get(fd, "format", "")
        type_desc = _parse_type_string(fd["type"], format_str)
        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthSchema(pairs...; record_width=record_width)
end

# --- JSON (implemented in ext/JSON3Ext.jl when JSON3 is loaded) ---

function _load_schema_json end
function _load_schema_json(path; record_width) end

# ---------------------------------------------------------------------------
# Multi-file load_schema → MultiRecordSchema
# ---------------------------------------------------------------------------

"""
    load_schema(path1, path2, paths...; discriminator=1:1, record_width=nothing) → MultiRecordSchema

Load multiple schema files and combine into a `MultiRecordSchema`.
Labels are derived from filenames (basename without extension).
Discriminator values are also derived from filenames.

**Note:** Bare-file mode uses filenames as discriminator values. For actual data
parsing, prefer the Pair-based form: `load_schema('H' => "header.csv", 'D' => "detail.csv")`.
"""
function load_schema(
    path1::AbstractString,
    path2::AbstractString,
    paths::AbstractString...;
    discriminator::Union{UnitRange{Int},Int}=1:1,
    record_width::Union{Int,Nothing}=nothing,
)
    all_paths = [path1, path2, paths...]
    disc_range = discriminator isa Int ? (discriminator:discriminator) : discriminator

    labels = _paths_to_labels(all_paths)
    disc_values = [string(label) for label in labels]

    schemas = [load_schema(p) for p in all_paths]

    string_pairs = Pair{String,FixedWidthSchema}[disc_values[i] => schemas[i] for i in eachindex(all_paths)]
    label_syms = collect(labels)
    _build_multi_record_schema(disc_range, string_pairs, label_syms, record_width)
end

"""
    load_schema(pair1, pair2, pairs...; discriminator=1:1, record_width=nothing) → MultiRecordSchema

Load multiple schema files with explicit discriminator values.
At least 2 pairs are required. Keys can be Char, Int, or String.
"""
function load_schema(
    pair1::Pair{T,<:AbstractString},
    pair2::Pair{T,<:AbstractString},
    pairs::Pair{T,<:AbstractString}...;
    discriminator::Union{UnitRange{Int},Int}=1:1,
    record_width::Union{Int,Nothing}=nothing,
) where {T}
    all_pairs = [pair1, pair2, pairs...]
    disc_range = discriminator isa Int ? (discriminator:discriminator) : discriminator

    loaded = [(k, load_schema(v)) for (k, v) in all_pairs]

    ms_pairs = [k => sch for (k, sch) in loaded]
    return MultiRecordSchema(disc_range, ms_pairs...; record_width=record_width)
end

# Single-pair overload that throws helpful error
function load_schema(
    pair::Pair{T,<:AbstractString};
    kwargs...,
) where {T}
    T <: AbstractString && return load_schema(pair.second; kwargs...)
    throw(ArgumentError("multi-record schema requires at least 2 record types"))
end

"""
    _paths_to_labels(paths) → Vector{Symbol}

Derive output labels from file paths. Uses basename without extension.
"""
function _paths_to_labels(paths::Vector)
    labels = Symbol[]
    for p in paths
        base = splitext(basename(p))[1]
        push!(labels, Symbol(base))
    end
    if length(unique(labels)) != length(labels)
        throw(ArgumentError(
            "schema file names produce duplicate labels: $(labels). " *
            "Use explicit Pair keys instead (e.g., 'H' => \"file.csv\").",
        ))
    end
    return labels
end
