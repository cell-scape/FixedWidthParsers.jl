using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field, FWString, FWInt, FWFloat, FWSkip,
                          FWDate, FWFixedPoint, Skip

@testset "Field Types" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "FWInt" begin
        buf = to_buf("  42")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        buf = to_buf("-123")
        @test parse_field(FWInt(), buf, 1, 4) == -123

        buf = to_buf("0007")
        @test parse_field(FWInt(), buf, 1, 4) == 7

        # Leading + is accepted
        buf = to_buf(" +42")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        # Trailing spaces after digits are accepted
        buf = to_buf("42  ")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        # Leading and trailing spaces around a signed value
        buf = to_buf(" -5 ")
        @test parse_field(FWInt(), buf, 1, 4) == -5
    end

    @testset "FWInt strictness — reject malformed integers" begin
        # Non-leading '-' must not flip the sign silently
        @test_throws ArgumentError parse_field(FWInt(), to_buf("1-23"), 1, 4)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("12-3"), 1, 4)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("5-"), 1, 2)

        # Non-leading '+' is also invalid
        @test_throws ArgumentError parse_field(FWInt(), to_buf("1+2"), 1, 3)

        # Double signs
        @test_throws ArgumentError parse_field(FWInt(), to_buf("--5"), 1, 3)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("++5"), 1, 3)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("-+5"), 1, 3)

        # Sign followed by space (no digit contiguous with the sign)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("-  5"), 1, 4)

        # Interior spaces between digits
        @test_throws ArgumentError parse_field(FWInt(), to_buf("1 2"), 1, 3)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("12 34"), 1, 5)

        # No digits at all
        @test_throws ArgumentError parse_field(FWInt(), to_buf("    "), 1, 4)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("-"), 1, 1)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("+"), 1, 1)
    end

    @testset "FWFloat" begin
        buf = to_buf("  3.14  ")
        @test parse_field(FWFloat(), buf, 1, 8) ≈ 3.14

        buf = to_buf("-1.5")
        @test parse_field(FWFloat(), buf, 1, 4) ≈ -1.5
    end

    @testset "FWString" begin
        buf = to_buf("UA ")
        val = parse_field(FWString(), buf, 1, 3)
        @test val == "UA"          # trailing spaces stripped
        @test typeof(val) <: AbstractString

        buf = to_buf("ORD")
        @test parse_field(FWString(), buf, 1, 3) == "ORD"
    end

    @testset "FWString with padding char" begin
        buf = to_buf("UA0")
        val = parse_field(FWString(pad='0'), buf, 1, 3)
        @test val == "UA"
    end

    @testset "FWString all-spaces returns empty string" begin
        buf = to_buf("   ")
        val = parse_field(FWString(), buf, 1, 3)
        @test val == ""
    end

    @testset "FWSkip" begin
        buf = to_buf("XXXXX")
        @test parse_field(FWSkip(), buf, 1, 5) === nothing
    end

    @testset "FWDate" begin
        buf = to_buf("20260224")
        val = parse_field(FWDate("yyyymmdd"), buf, 1, 8)
        @test val == Date(2026, 2, 24)
    end

    @testset "FWFixedPoint" begin
        buf = to_buf("00012345")
        val = parse_field(FWFixedPoint(2), buf, 1, 8)
        @test val ≈ 123.45

        buf = to_buf("  500")
        val = parse_field(FWFixedPoint(2), buf, 1, 5)
        @test val ≈ 5.0
    end
end
