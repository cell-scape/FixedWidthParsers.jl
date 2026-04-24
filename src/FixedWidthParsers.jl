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
export parse_file, parse_string, parse_bytes
export @fixedwidth, schema
export load_schema
export MultiRecordSchema
export SSIM_SCHEMA
export AIRCRAFT_SCHEMA, AIRPORT_SCHEMA, MCT_SCHEMA, MCT_PRIORITY_SCHEMA
export REGIONAL_SCHEMA, SEATS_SCHEMA

"""
    to_duckdb(con, table_name, source, schema; kwargs...)

Stream-parse a fixed-width file/IO into a DuckDB table without materializing
the whole file in memory. Method is provided by the `DuckDBExt` package
extension — `using DuckDB` must be active for this function to dispatch.

See the `DuckDBExt` module for the full keyword-argument list.
"""
function to_duckdb end
export to_duckdb

end # module
