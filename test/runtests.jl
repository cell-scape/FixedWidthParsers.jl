using Test
using FixedWidthParsers
using Dates
using StructArrays

@testset "FixedWidthParsers.jl" begin
    include("test_aqua.jl")
    include("test_jet.jl")
    include("test_types.jl")
    include("test_schema.jl")
    include("test_io.jl")
    include("test_parsing.jl")
    include("test_iteration.jl")
    include("test_materialization.jl")
    include("test_errors.jl")
    include("test_macro.jl")
    include("test_integration.jl")
    include("test_parallel.jl")
    include("test_skipping.jl")
    include("test_column_selection.jl")
    include("test_schema_loading.jl")
    include("test_bool.jl")
    include("test_custom_pad.jl")
    include("test_defaults.jl")
    include("test_transforms.jl")
    include("test_schema_show.jl")
    include("test_multi_record.jl")
    include("test_generated.jl")
    include("test_time_datetime.jl")
    include("test_custom_field.jl")
end
