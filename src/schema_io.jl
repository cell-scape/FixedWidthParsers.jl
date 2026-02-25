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

    # Parse data rows
    pairs = Pair{Symbol,Tuple{UnitRange{Int},Any}}[]
    for line in lines[2:end]
        parts = strip.(split(line, ','))
        name = Symbol(parts[idx[:name]])
        start_byte = parse(Int, parts[idx[:start]])
        end_byte = parse(Int, parts[idx[:end]])
        type_desc = _parse_type_string(parts[idx[:type]])
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
        type_desc = _parse_type_string(fd["type"])
        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthSchema(pairs...; record_width=record_width)
end

# --- JSON (implemented in ext/JSON3Ext.jl when JSON3 is loaded) ---

function _load_schema_json end
function _load_schema_json(path; record_width) end
