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

    @testset "FWTime fast paths" begin
        @test FWTime("HHMM")     isa FWTime{:HHMM}
        @test FWTime("HHMMSS")   isa FWTime{:HHMMSS}
        @test FWTime("HH:MM")    isa FWTime{:HH_MM}
        @test FWTime("HH:MM:SS") isa FWTime{:HH_MM_SS}
        @test FWTime("Hmm")      isa FWTime{:generic}
        @test FWTime()           isa FWTime{:HH_MM}   # default format

        # Fast-path correctness matches Dates.jl
        buf = Vector{UInt8}("0930")
        @test FixedWidthParsers.parse_field(FWTime("HHMM"), buf, 1, 4) == Time(9, 30)
        buf = Vector{UInt8}("093045")
        @test FixedWidthParsers.parse_field(FWTime("HHMMSS"), buf, 1, 6) == Time(9, 30, 45)
        buf = Vector{UInt8}("09:30")
        @test FixedWidthParsers.parse_field(FWTime("HH:MM"), buf, 1, 5) == Time(9, 30)
        buf = Vector{UInt8}("09:30:45")
        @test FixedWidthParsers.parse_field(FWTime("HH:MM:SS"), buf, 1, 8) == Time(9, 30, 45)

        # Invalid time: hour 25 throws through Time(h,m,s) constructor
        buf = Vector{UInt8}("2530")
        @test_throws ArgumentError FixedWidthParsers.parse_field(FWTime("HHMM"), buf, 1, 4)

        # ISO fast path validates separators
        buf = Vector{UInt8}("09X30")
        @test_throws ArgumentError FixedWidthParsers.parse_field(FWTime("HH:MM"), buf, 1, 5)
    end
end

@testset "FWDateTime" begin
    @testset "basic parsing with full format" begin
        desc = FWDateTime("yyyy-mm-ddTHH:MM:SS")
        buf = Vector{UInt8}("2026-03-17T14:30:00")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 19)
        @test result == DateTime(2026, 3, 17, 14, 30, 0)
    end

    @testset "compact format" begin
        desc = FWDateTime("yyyymmddHHMM")
        buf = Vector{UInt8}("202603171430")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 12)
        @test result == DateTime(2026, 3, 17, 14, 30)
    end

    @testset "zero-argument constructor defaults to yyyy-mm-ddTHH:MM:SS" begin
        desc = FWDateTime()
        @test desc.format_string == "yyyy-mm-ddTHH:MM:SS"
    end

    @testset "stores format_string" begin
        desc = FWDateTime("yyyymmddHHMM")
        @test desc.format_string == "yyyymmddHHMM"
    end

    @testset "default value" begin
        desc = FWDateTime("yyyymmddHHMM"; default=DateTime(1))
        @test desc.default == DateTime(1)
    end

    @testset "transform" begin
        desc = FWDateTime("yyyymmddHHMM"; transform=identity)
        @test desc.transform !== nothing
    end

    @testset "_parse_type_string round-trip" begin
        desc = _parse_type_string("DateTime")
        @test desc isa FWDateTime
        @test desc.format_string == "yyyy-mm-ddTHH:MM:SS"
        desc2 = _parse_type_string("DateTime(yyyymmddHHMM)")
        @test desc2 isa FWDateTime
        @test desc2.format_string == "yyyymmddHHMM"
    end

    @testset "integration with parse_file" begin
        schema = FixedWidthSchema(:dt => (1:12, FWDateTime("yyyymmddHHMM")))
        path = tempname()
        open(path, "w") do io
            write(io, "202603171430\n202603180900\n")
        end
        result = parse_file(path, schema)
        @test result.dt == [DateTime(2026, 3, 17, 14, 30), DateTime(2026, 3, 18, 9, 0)]
        rm(path)
    end

    @testset "FWDateTime fast paths" begin
        @test FWDateTime("yyyymmddHHMM")   isa FWDateTime{:yyyymmddHHMM}
        @test FWDateTime("yyyymmddHHMMSS") isa FWDateTime{:yyyymmddHHMMSS}
        @test FWDateTime("weirdo")         isa FWDateTime{:generic}

        buf = Vector{UInt8}("202603171430")
        @test FixedWidthParsers.parse_field(FWDateTime("yyyymmddHHMM"), buf, 1, 12) ==
            DateTime(2026, 3, 17, 14, 30)
        buf = Vector{UInt8}("20260317143045")
        @test FixedWidthParsers.parse_field(FWDateTime("yyyymmddHHMMSS"), buf, 1, 14) ==
            DateTime(2026, 3, 17, 14, 30, 45)
    end
end
