using Test
using Dates
using FixedWidthParsers
using FixedWidthParsers: _parse_type_string

@testset "FWTime" begin
    @testset "basic parsing with HH:MM format" begin
        desc = FWTime("HH:MM")
        buf = Vector{UInt8}("14:30")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 5)
        @test result == Time(14, 30)
    end

    @testset "parsing with HHMM format" begin
        desc = FWTime("HHMM")
        buf = Vector{UInt8}("0830")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 4)
        @test result == Time(8, 30)
    end

    @testset "parsing with HH:MM:SS format" begin
        desc = FWTime("HH:MM:SS")
        buf = Vector{UInt8}("09:15:30")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 8)
        @test result == Time(9, 15, 30)
    end

    @testset "zero-argument constructor defaults to HH:MM" begin
        desc = FWTime()
        @test desc.format_string == "HH:MM"
    end

    @testset "stores format_string" begin
        desc = FWTime("HHMM")
        @test desc.format_string == "HHMM"
    end

    @testset "default value" begin
        desc = FWTime("HHMM"; default=Time(0, 0))
        @test desc.default == Time(0, 0)
    end

    @testset "transform" begin
        desc = FWTime("HHMM"; transform=t -> t + Dates.Hour(1))
        @test desc.transform !== nothing
    end

    @testset "_parse_type_string round-trip" begin
        desc = _parse_type_string("Time")
        @test desc isa FWTime
        @test desc.format_string == "HH:MM"
        desc2 = _parse_type_string("Time(HHMM)")
        @test desc2 isa FWTime
        @test desc2.format_string == "HHMM"
    end

    @testset "integration with parse_file" begin
        schema = FixedWidthSchema(:t => (1:5, FWTime("HH:MM")))
        path = tempname()
        open(path, "w") do io
            write(io, "14:30\n09:15\n")
        end
        result = parse_file(path, schema)
        @test result.t == [Time(14, 30), Time(9, 15)]
        rm(path)
    end
end
