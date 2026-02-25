module JSON3Ext

using FixedWidthParsers
import JSON3

function FixedWidthParsers._load_schema_json(
    path::AbstractString;
    record_width::Union{Int,Nothing}=nothing,
)
    data = JSON3.read(read(path, String))
    haskey(data, :fields) || throw(ArgumentError("JSON schema file missing \"fields\" key"))
    field_defs = data[:fields]

    pairs = Pair{Symbol,Tuple{UnitRange{Int},Any}}[]
    for (i, fd) in enumerate(field_defs)
        for key in (:name, :start, :end, :type)
            haskey(fd, key) || throw(ArgumentError(
                "JSON field entry $i missing required key: $key"
            ))
        end
        name = Symbol(fd[:name])
        start_byte = fd[:start]::Int
        end_byte = fd[:end]::Int
        type_desc = FixedWidthParsers._parse_type_string(fd[:type])
        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthParsers.FixedWidthSchema(pairs...; record_width=record_width)
end

end # module
