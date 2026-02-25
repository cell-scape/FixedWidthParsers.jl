using Test
using FixedWidthParsers
using FixedWidthParsers: ParseError

@testset "Error Handling" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    @testset "ParseError type" begin
        err = ParseError(1, 5:7, UInt8[0x41, 0x42, 0x43], Int, "bad int")
        @test err.line == 1
        @test err.columns == 5:7
        @test err.expected_type == Int
        @test occursin("bad int", err.message)
    end

    @testset "strict mode throws on bad data" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo abc\n")  # "abc" is not a valid Int
        end
        @test_throws ParseError parse_file(path, schema; on_error=:strict)
        rm(path)
    end

    @testset "default mode is strict" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo abc\n")
        end
        @test_throws ParseError parse_file(path, schema)
        rm(path)
    end

    @testset "lenient mode returns missing" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo abc\n")
            write(io, "bar  42\n")
        end
        result = parse_file(path, schema; on_error=:lenient)
        @test length(result) == 2
        @test ismissing(result.val[1])
        @test result.val[2] == 42
        @test result.name[1] == "foo"
        rm(path)
    end

    @testset "lenient mode row-oriented" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo abc\n")
            write(io, "bar  42\n")
        end
        result = parse_file(path, schema; on_error=:lenient, columnar=false)
        @test length(result) == 2
        @test ismissing(result[1].val)
        @test result[2].val == 42
        rm(path)
    end
end
