using Test
using FixedWidthParsers
using FixedWidthParsers: _is_blank

@testset "Default Values" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "_is_blank helper" begin
        @test _is_blank(to_buf("   "), 1, 3, UInt8(' ')) === true
        @test _is_blank(to_buf("  X"), 1, 3, UInt8(' ')) === false
        @test _is_blank(to_buf("000"), 1, 3, UInt8('0')) === true
        @test _is_blank(to_buf("001"), 1, 3, UInt8('0')) === false
    end

    @testset "FWInt with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n  99\n")
        end
        schema = FixedWidthSchema(:val => (4, FWInt(default=0)))
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val == [42, 0, 99]
        @test eltype(sa.val) === Int
        rm(path)
    end

    @testset "FWString with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AB\n  \nCD\n")
        end
        schema = FixedWidthSchema(:val => (2, FWString(default="??")))
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val[1] == "AB"
        @test String(sa.val[2]) == "??"
        @test sa.val[3] == "CD"
        rm(path)
    end

    @testset "FWFloat with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  3.14\n      \n  1.00\n")
        end
        schema = FixedWidthSchema(:val => (6, FWFloat(default=0.0)))
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val[1] ≈ 3.14
        @test sa.val[2] ≈ 0.0
        @test sa.val[3] ≈ 1.0
        rm(path)
    end

    @testset "FWBool with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "Y\n \nN\n")
        end
        schema = FixedWidthSchema(:val => (1, FWBool(default=false)))
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val == [true, false, false]
        rm(path)
    end

    @testset "no default: blank in :default mode throws" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n")
        end
        schema = FixedWidthSchema(:val => (4, FWInt()))
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:default)
        rm(path)
    end

    @testset "malformed data in :default mode throws" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  XY\n")
        end
        schema = FixedWidthSchema(:val => (4, FWInt(default=0)))
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:default)
        rm(path)
    end

    @testset "zero-padded blank detection" begin
        path = tempname()
        open(path, "w") do io
            write(io, "0042\n0000\n0099\n")
        end
        schema = FixedWidthSchema(:val => (4, FWInt(pad='0', default=-1)))
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val == [42, -1, 99]
        rm(path)
    end

    @testset ":default mode column type is Vector{T}" begin
        path = tempname()
        open(path, "w") do io
            write(io, "42\n")
        end
        schema = FixedWidthSchema(:val => (2, FWInt(default=0)))
        sa = parse_file(path, schema; on_error=:default)
        @test eltype(sa.val) === Int
        rm(path)
    end

    @testset "row-oriented :default mode" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n")
        end
        schema = FixedWidthSchema(:val => (4, FWInt(default=0)))
        rows = parse_file(path, schema; columnar=false, on_error=:default)
        @test rows[1].val == 42
        @test rows[2].val == 0
        rm(path)
    end
end
