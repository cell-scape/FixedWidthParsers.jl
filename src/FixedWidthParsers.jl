module FixedWidthParsers

using Dates

include("types.jl")
include("schema.jl")
include("io.jl")
include("parsing.jl")
include("iteration.jl")
include("materialization.jl")
include("schema_io.jl")
include("multi_record.jl")
include("bundled_schemas.jl")

export FWString, FWInt, FWFloat, FWDate, FWTime, FWDateTime, FWSkip, FWFixedPoint, FWBool, FWCustom, Skip
export ParseError
export parse_field
export FixedWidthSchema
export parse_record
export eachrecord
export parse_file
export @fixedwidth, schema
export load_schema
export MultiRecordSchema
export SSIM_SCHEMA
export AIRCRAFT_SCHEMA, AIRPORT_SCHEMA, MCT_SCHEMA, MCT_PRIORITY_SCHEMA
export REGIONAL_SCHEMA, SEATS_SCHEMA

end # module
