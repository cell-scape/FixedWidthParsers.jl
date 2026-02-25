using Test
using FixedWidthParsers
using StructArrays
using Tables

@testset "Materialization" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    function make_test_file()
        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end
        return path
    end

    @testset "parse_file returns StructArray by default" begin
        path = make_test_file()
        result = parse_file(path, schema)
        @test result isa StructArray
        @test length(result) == 3
        @test result.name[1] == "foo"
        @test result.val == [10, 20, 30]
        rm(path)
    end

    @testset "parse_file columnar=false returns Vector" begin
        path = make_test_file()
        result = parse_file(path, schema; columnar=false)
        @test result isa Vector
        @test length(result) == 3
        @test result[1].name == "foo"
        @test result[1].val == 10
        rm(path)
    end

    @testset "parse_file empty file" begin
        path = tempname()
        open(path, "w") do io end
        result = parse_file(path, schema)
        @test length(result) == 0
        rm(path)
    end

    @testset "parse_file with skip fields" begin
        schema_with_skip = FixedWidthSchema(
            :a    => (2, FWString()),
            :skip => (1, FWSkip()),
            :b    => (3, FWInt()),
        )
        path = tempname()
        open(path, "w") do io
            write(io, "AB 123\n")
            write(io, "CD 456\n")
        end

        result = parse_file(path, schema_with_skip)
        @test hasproperty(result, :a)
        @test hasproperty(result, :b)
        @test !hasproperty(result, :skip)
        @test result.a == ["AB", "CD"]
        @test result.b == [123, 456]
        rm(path)
    end

    @testset "Tables.jl interface" begin
        tables_schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        tables_path = tempname()
        open(tables_path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
        end

        @testset "StructArray is a table" begin
            result = parse_file(tables_path, tables_schema)
            @test Tables.istable(typeof(result))
            @test Tables.columnaccess(typeof(result))

            cols = Tables.columns(result)
            @test Tables.getcolumn(cols, :name) == ["foo", "bar"]
            @test Tables.getcolumn(cols, :val) == [10, 20]
        end

        @testset "RecordIterator is a table" begin
            iter = eachrecord(tables_path, tables_schema)
            @test Tables.istable(typeof(iter))
            @test Tables.rowaccess(typeof(iter))

            rows = collect(Tables.rows(iter))
            @test length(rows) == 2
            @test Tables.getcolumn(rows[1], :name) == "foo"
            @test Tables.getcolumn(rows[1], :val) == 10
        end

        rm(tables_path)
    end
end
