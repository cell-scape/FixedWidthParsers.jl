"""
    parsing.jl — Record-level parsing built on top of `parse_field`.

The primary entry point is `parse_record`, which walks the fields of a
`FixedWidthSchema`, skips any `FWSkip` columns, and returns a `NamedTuple`
containing one entry per non-skip field.
"""

# ---------------------------------------------------------------------------
# parse_record
# ---------------------------------------------------------------------------

"""
    parse_record(schema::FixedWidthSchema, buf, pos) → NamedTuple

Parse a single record from `buf` starting at 1-based byte position `pos`.
Returns a `NamedTuple` whose keys are the non-skip field names and whose
values are the parsed field values.

`FWSkip` fields are silently omitted from the output; all other fields are
parsed using the `parse_field` dispatch defined in `types.jl`.

# Arguments
- `schema` — the `FixedWidthSchema` describing the record layout
- `buf`    — byte buffer (`AbstractVector{UInt8}`) containing the raw data
- `pos`    — 1-based index of the first byte of the record within `buf`

# Example

```julia
schema = FixedWidthSchema(
    :carrier    => (2, FWString()),
    :flight_num => (4, FWInt()),
    :_pad       => (1, FWSkip()),
    :origin     => (3, FWString()),
)

buf    = Vector{UInt8}("UA1234 ORD")
record = parse_record(schema, buf, 1)
record.carrier    # "UA"
record.flight_num # 1234
record.origin     # "ORD"
# :_pad is not present in the output
```
"""
function parse_record(schema::FixedWidthSchema, buf::AbstractVector{UInt8}, pos::Int)
    ns = schema._output_fields
    n = length(ns)
    values = ntuple(n) do i
        @inbounds f = ns[i]
        parse_field(f.type, buf, pos + f.offset - 1, f.width)
    end
    return NamedTuple{schema._output_names}(values)
end
