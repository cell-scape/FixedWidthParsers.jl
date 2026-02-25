using JET

@testset "JET.jl" begin
    test_package(FixedWidthParsers; 
                 ignore_missing_comparison=true, 
                 ignore_throws=true, 
                 target_modules=(FixedWidthParsers,),
                 toplevel_logger=nothing)
end
