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

    @testset "row-oriented path returns concrete NamedTuple eltype" begin
        # Regression guard: before the row-path rewrite, this returned
        # Vector{NamedTuple} with an ABSTRACT NamedTuple eltype — every row was
        # heap-boxed and dispatch went through Any for each field. The rewrite
        # delegates to the columnar path and transposes, so the eltype must now
        # be a concrete NamedTuple{names, Tuple{types...}}.
        path = make_test_file()
        result = parse_file(path, schema; columnar=false)
        ET = eltype(result)
        @test isconcretetype(ET)
        @test ET <: NamedTuple
        @test fieldnames(ET) == (:name, :val)
        rm(path)
    end

    @testset "row-oriented values match columnar" begin
        path = make_test_file()
        sa  = parse_file(path, schema)
        rows = parse_file(path, schema; columnar=false)
        @test length(rows) == length(sa)
        for i in 1:length(sa)
            @test rows[i].name == sa.name[i]
            @test rows[i].val  == sa.val[i]
        end
        rm(path)
    end

    @testset "row-oriented lenient mode yields Union{T, Missing} fields" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar abc\n")   # parse error on :val
            write(io, "baz  30\n")
        end
        rows = parse_file(path, schema; columnar=false, on_error=:lenient)
        ET = eltype(rows)
        @test isconcretetype(ET)
        @test fieldtype(ET, :val) == Union{Int, Missing}
        @test rows[1].val == 10
        @test ismissing(rows[2].val)
        @test rows[3].val == 30
        rm(path)
    end

    @testset "row-oriented path: indexed variant (skip_header/footer/comment)" begin
        # Each line is 7 bytes (name[4] + val[3]) + '\n'
        path = tempname()
        open(path, "w") do io
            write(io, "HDR  99\n")   # header (skip)
            write(io, "# cmnt \n")   # comment (filtered by comment=UInt8('#'))
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "FTR  99\n")   # footer (skip)
        end
        rows = parse_file(path, schema;
                          columnar=false, skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(rows) == 2
        @test rows[1].name == "foo"
        @test rows[2].val  == 20
        @test isconcretetype(eltype(rows))
        rm(path)
    end

    @testset "row-oriented throughput closes most of the 40× gap vs columnar" begin
        # 200k records, 24 bytes each — enough for meaningful timing.
        path = tempname()
        open(path, "w") do io
            for i in 1:200_000
                c  = ("UA","DL","AA","WN")[((i-1) % 4) + 1]
                fn = lpad(1000 + (i % 9000), 4)
                o  = ("ORD","LAX","JFK","SFO","DEN")[((i-1) % 5) + 1]
                d  = ("ORD","LAX","JFK","SFO","DEN")[((i*3-1) % 5) + 1]
                px = lpad(50 + (i % 250), 3)
                rv = lpad(100000 + i*7, 8, '0')
                write(io, c, fn, " ", o, d, px, rv, "\n")
            end
        end
        wide_schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :skip    => (1, FWSkip()),
            :origin  => (3, FWString()),
            :dest    => (3, FWString()),
            :pax     => (3, FWInt()),
            :revenue => (8, FWInt()),
        )
        # Warm
        parse_file(path, wide_schema; columnar=true)
        parse_file(path, wide_schema; columnar=false)
        t_col = minimum(@elapsed(parse_file(path, wide_schema; columnar=true))  for _ in 1:3)
        t_row = minimum(@elapsed(parse_file(path, wide_schema; columnar=false)) for _ in 1:3)
        # Before the fix, rows were ~40× slower than columnar. After the fix,
        # they should be within ~5× (rows still allocate a Vector{NT} on top of
        # the columnar storage). 10× is a forgiving threshold for CI noise.
        @test t_row / t_col < 10
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
