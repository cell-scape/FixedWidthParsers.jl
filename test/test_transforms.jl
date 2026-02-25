using Test
using Dates
using FixedWidthParsers

@testset "Post-Parse Transforms" begin

    @testset "FWString with uppercase transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "abc\ndef\n")
        end
        schema = FixedWidthSchema(
            :val => (3, FWString(transform=uppercase)),
        )
        sa = parse_file(path, schema)
        @test sa.val[1] == "ABC"
        @test sa.val[2] == "DEF"
        rm(path)
    end

    @testset "FWFloat with rounding transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "3.14159\n2.71828\n")
        end
        schema = FixedWidthSchema(
            :val => (7, FWFloat(transform=x -> round(x, digits=2))),
        )
        sa = parse_file(path, schema)
        @test sa.val[1] ≈ 3.14
        @test sa.val[2] ≈ 2.72
        rm(path)
    end

    @testset "FWBool with negation transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "Y\nN\n")
        end
        schema = FixedWidthSchema(
            :val => (1, FWBool(transform=!)),
        )
        sa = parse_file(path, schema)
        @test sa.val == [false, true]
        rm(path)
    end

    @testset "transform with :default mode applies to defaults" begin
        path = tempname()
        open(path, "w") do io
            write(io, "abc\n   \n")
        end
        schema = FixedWidthSchema(
            :val => (3, FWString(default="zzz", transform=uppercase)),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val[1] == "ABC"
        @test sa.val[2] == "ZZZ"
        rm(path)
    end

    @testset "transform NOT applied to missing in :lenient" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  XY\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(transform=x -> x * 2)),
        )
        sa = parse_file(path, schema; on_error=:lenient)
        @test sa.val[1] == 84
        @test sa.val[2] === missing
        rm(path)
    end

    @testset "transform error in :strict mode throws ParseError" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  -1\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(transform=x -> x < 0 ? error("negative!") : x)),
        )
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:strict)
        rm(path)
    end

    @testset "transform error in :lenient mode returns missing" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  -1\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(transform=x -> x < 0 ? error("negative!") : x)),
        )
        sa = parse_file(path, schema; on_error=:lenient)
        @test sa.val[1] == 42
        @test sa.val[2] === missing
        rm(path)
    end

    @testset "column type is Any when transform is set" begin
        path = tempname()
        open(path, "w") do io
            write(io, "42\n")
        end
        schema = FixedWidthSchema(:val => (2, FWInt(transform=string)))
        sa = parse_file(path, schema)
        @test sa.val[1] == "42"
        @test eltype(sa.val) === Any
        rm(path)
    end

    @testset "row-oriented transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "abc\ndef\n")
        end
        schema = FixedWidthSchema(:val => (3, FWString(transform=uppercase)))
        rows = parse_file(path, schema; columnar=false)
        @test rows[1].val == "ABC"
        @test rows[2].val == "DEF"
        rm(path)
    end

    @testset "transform error on default value in :default mode throws ParseError" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(default=-1, transform=x -> x < 0 ? error("negative!") : x)),
        )
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:default)
        rm(path)
    end

    @testset "FWDate with transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "20240101\n20240615\n")
        end
        schema = FixedWidthSchema(:val => (8, FWDate("yyyymmdd", transform=d -> Dates.year(d))))
        sa = parse_file(path, schema)
        @test sa.val[1] == 2024
        @test sa.val[2] == 2024
        rm(path)
    end
end
