using Test
using FixedWidthParsers
using FixedWidthParsers: _partition_ranges, @fixedwidth, Skip

@testset "Parallel Parsing" begin
    @testset "_partition_ranges" begin
        @test _partition_ranges(10, 1) == [1:10]
        @test _partition_ranges(10, 2) == [1:5, 6:10]
        @test _partition_ranges(10, 3) == [1:4, 5:7, 8:10]
        @test _partition_ranges(10, 4) == [1:3, 4:6, 7:8, 9:10]
        @test _partition_ranges(10, 10) == [i:i for i in 1:10]
        # ntasks > n gets clamped
        @test _partition_ranges(3, 10) == [1:1, 2:2, 3:3]
        @test _partition_ranges(1, 4) == [1:1]
    end

    @testset "parse_file with ntasks keyword" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, lpad("r$i", 4)[1:4] * lpad(string(i), 3) * "\n")
            end
        end

        @testset "ntasks=1 matches default" begin
            baseline = parse_file(path, schema)
            result = parse_file(path, schema; ntasks=1)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end

        @testset "ntasks=2 produces correct results" begin
            baseline = parse_file(path, schema)
            result = parse_file(path, schema; ntasks=2)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end

        @testset "ntasks=4 produces correct results" begin
            baseline = parse_file(path, schema)
            result = parse_file(path, schema; ntasks=4)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end

        @testset "ntasks > n_records is clamped" begin
            small_path = tempname()
            open(small_path, "w") do io
                write(io, "foo  10\n")
                write(io, "bar  20\n")
            end
            result = parse_file(small_path, schema; ntasks=100)
            @test result.val == [10, 20]
            rm(small_path)
        end

        rm(path)
    end

    @testset "parse_file ntasks with @fixedwidth struct" begin
        @fixedwidth struct ParTestFlight
            carrier::String = 2
            number::Int     = 4
            origin::String  = 3
        end

        path = tempname()
        open(path, "w") do io
            for i in 1:100
                carrier = "UA"
                number = lpad(string(i), 4)
                origin = "ORD"
                write(io, carrier * number * origin * "\n")
            end
        end

        baseline = parse_file(path, ParTestFlight)

        @testset "ntasks=$nt" for nt in [1, 2, 4]
            result = parse_file(path, ParTestFlight; ntasks=nt)
            @test result.carrier == baseline.carrier
            @test result.number == baseline.number
            @test result.origin == baseline.origin
        end

        rm(path)
    end

    @testset "parallel error handling" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        @testset "strict mode throws ParseError with ntasks=2" begin
            path = tempname()
            open(path, "w") do io
                write(io, "foo  10\n")
                write(io, "bar abc\n")  # bad int in second record
                write(io, "baz  30\n")
            end
            err = try
                parse_file(path, schema; ntasks=2)
                nothing
            catch e
                e
            end
            @test err isa ParseError
            @test err.line == 2
            rm(path)
        end

        @testset "lenient mode returns missing with ntasks=2" begin
            path = tempname()
            open(path, "w") do io
                write(io, "foo abc\n")
                write(io, "bar  42\n")
                write(io, "baz def\n")
                write(io, "qux  99\n")
            end
            result = parse_file(path, schema; on_error=:lenient, ntasks=2)
            @test length(result) == 4
            @test ismissing(result.val[1])
            @test result.val[2] == 42
            @test ismissing(result.val[3])
            @test result.val[4] == 99
            rm(path)
        end
    end

    @testset "parallel with empty file" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = tempname()
        open(path, "w") do io end
        result = parse_file(path, schema; ntasks=4)
        @test length(result) == 0
        rm(path)
    end
end
