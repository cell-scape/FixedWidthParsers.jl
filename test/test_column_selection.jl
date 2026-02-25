using Test
using FixedWidthParsers
using FixedWidthParsers: _apply_column_selection, record_width

@testset "Column Selection" begin
    @testset "_apply_column_selection" begin
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :_pad    => (1, FWSkip()),
            :origin  => (3, FWString()),
        )

        @testset "both nothing returns same schema" begin
            result = _apply_column_selection(schema, nothing, nothing)
            @test result === schema
        end

        @testset "select keeps only named columns" begin
            result = _apply_column_selection(schema, [:carrier, :origin], nothing)
            @test length(result._output_fields) == 2
            @test result._output_names == (:carrier, :origin)
            @test record_width(result) == record_width(schema)
        end

        @testset "exclude removes named columns" begin
            result = _apply_column_selection(schema, nothing, [:fnum])
            @test length(result._output_fields) == 2
            @test result._output_names == (:carrier, :origin)
            @test record_width(result) == record_width(schema)
        end

        @testset "both provided throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, [:carrier], [:fnum])
        end

        @testset "unknown column in select throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, [:nonexistent], nothing)
        end

        @testset "unknown column in exclude throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, nothing, [:nonexistent])
        end

        @testset "selecting a FWSkip field throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, [:_pad], nothing)
        end

        @testset "select preserves existing FWSkip fields" begin
            result = _apply_column_selection(schema, [:carrier], nothing)
            # _pad was already FWSkip, carrier is kept, fnum+origin become FWSkip
            @test length(result._output_fields) == 1
            @test result._output_names == (:carrier,)
            @test record_width(result) == record_width(schema)
        end

        @testset "exclude a FWSkip field is a no-op" begin
            result = _apply_column_selection(schema, nothing, [:_pad])
            # _pad was already FWSkip — excluding it changes nothing
            @test result._output_names == (:carrier, :fnum, :origin)
        end
    end

    @testset "parse_file with select" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; select=[:name, :code])
        @test length(result) == 2
        @test hasproperty(result, :name)
        @test hasproperty(result, :code)
        @test !hasproperty(result, :val)
        @test result.name == ["foo", "bar"]
        @test result.code == ["AB", "CD"]
        rm(path)
    end

    @testset "parse_file with exclude" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; exclude=[:val])
        @test length(result) == 2
        @test hasproperty(result, :name)
        @test hasproperty(result, :code)
        @test !hasproperty(result, :val)
        rm(path)
    end

    @testset "parse_file select + exclude throws" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
        end

        @test_throws ArgumentError parse_file(path, schema; select=[:name], exclude=[:val])
        rm(path)
    end

    @testset "parse_file with select row-oriented" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; columnar=false, select=[:name])
        @test length(result) == 2
        @test haskey(result[1], :name)
        @test !haskey(result[1], :val)
        rm(path)
    end

    @testset "parse_file with select + parallel" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, lpad("r$i", 4)[1:4] * lpad(string(i), 3) * "AB\n")
            end
        end

        baseline = parse_file(path, schema; select=[:name, :code], ntasks=1)
        result = parse_file(path, schema; select=[:name, :code], ntasks=4)
        @test result.name == baseline.name
        @test result.code == baseline.code
        rm(path)
    end

    @testset "parse_file with select + skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --HH\n")
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; select=[:name], skip_header=1)
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test !hasproperty(result, :val)
        rm(path)
    end

    @testset "eachrecord with select" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        records = collect(eachrecord(path, schema; select=[:name]))
        @test length(records) == 2
        @test haskey(records[1], :name)
        @test !haskey(records[1], :val)
        @test records[1].name == "foo"
        rm(path)
    end

    @testset "eachrecord IO with exclude" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        data = "foo  10AB\nbar  20CD\n"
        io = IOBuffer(data)

        records = collect(eachrecord(io, schema; exclude=[:val]))
        @test length(records) == 2
        @test haskey(records[1], :name)
        @test haskey(records[1], :code)
        @test !haskey(records[1], :val)
    end

    @testset "@fixedwidth with select" begin
        @fixedwidth struct ColSelFlight
            carrier::String = 2
            number::Int     = 4
            origin::String  = 3
        end

        path = tempname()
        open(path, "w") do io
            for i in 1:10
                write(io, "UA" * lpad(string(i), 4) * "ORD\n")
            end
        end

        result = parse_file(path, ColSelFlight; select=[:carrier, :origin])
        @test length(result) == 10
        @test hasproperty(result, :carrier)
        @test hasproperty(result, :origin)
        @test !hasproperty(result, :number)

        records = collect(eachrecord(path, ColSelFlight; select=[:carrier]))
        @test length(records) == 10
        @test haskey(records[1], :carrier)
        @test !haskey(records[1], :number)

        result_excl = parse_file(path, ColSelFlight; exclude=[:number])
        @test hasproperty(result_excl, :carrier)
        @test hasproperty(result_excl, :origin)
        @test !hasproperty(result_excl, :number)

        rm(path)
    end
end
