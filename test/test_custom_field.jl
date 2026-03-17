using Test
using FixedWidthParsers

@testset "FWCustom" begin
    @testset "string mode — basic" begin
        desc = FWCustom(Int, s -> length(strip(s)))
        buf = Vector{UInt8}("hello")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 5)
        @test result == 5
    end

    @testset "string mode — with trimming" begin
        desc = FWCustom(String, s -> uppercase(strip(s)))
        buf = Vector{UInt8}("abc  ")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 5)
        @test result == "ABC"
    end

    @testset "byte mode — raw access" begin
        desc = FWCustom(UInt8, (buf, pos, len) -> buf[pos]; raw=true)
        buf = Vector{UInt8}("XY")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 2)
        @test result == UInt8('X')
    end

    @testset "default value" begin
        desc = FWCustom(Int, s -> length(s); default=0)
        @test desc.default == 0
    end

    @testset "transform" begin
        desc = FWCustom(Int, s -> parse(Int, strip(s)); transform=x -> x * 2)
        @test desc.transform !== nothing
    end

    @testset "type parameters are concrete" begin
        fn = s -> parse(Int, s)
        desc = FWCustom(Int, fn)
        @test typeof(desc).parameters[1] === typeof(fn)
    end

    @testset "integration with parse_file" begin
        schema = FixedWidthSchema(
            :name  => (5, FWString()),
            :len   => (3, FWCustom(Int, s -> length(strip(s)))),
        )
        path = tempname()
        open(path, "w") do io
            write(io, "HelloABC\nWorld XY\n")
        end
        result = parse_file(path, schema)
        @test result.len == [3, 2]
        rm(path)
    end
end
