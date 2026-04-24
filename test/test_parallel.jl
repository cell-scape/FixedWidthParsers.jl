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

    # ----- Row-chunk-parallel shape tests (added with the reshape) -----

    @testset "wide schema parallel correctness (50 int columns)" begin
        # Stresses the new row-chunk shape: many columns + multi-task row
        # partitioning. Verifies values match ntasks=1 baseline exactly.
        wide = FixedWidthSchema([Symbol("f", i) => (4, FWInt()) for i in 1:50]...)
        path = tempname()
        open(path, "w") do io
            for i in 1:1_000
                for j in 1:50
                    write(io, lpad(string((i * j) % 9999), 4))
                end
                write(io, '\n')
            end
        end
        baseline = parse_file(path, wide)
        for nt in (2, 4, 8)
            result = parse_file(path, wide; ntasks=nt)
            for col_name in propertynames(result)
                @test getproperty(result, col_name) == getproperty(baseline, col_name)
            end
        end
        rm(path)
    end

    @testset "parallel with indexed path (skip_header/footer/comment)" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = tempname()
        open(path, "w") do io
            write(io, "HDR  99\n")     # header (skipped)
            write(io, "# cmnt \n")     # comment (filtered)
            for i in 1:500
                name = lpad("r$i", 4)[1:4]
                write(io, name * lpad(string(i), 3) * "\n")
            end
            write(io, "# cmnt \n")     # comment mid-file
            for i in 501:1_000
                name = lpad("r$i", 4)[1:4]
                write(io, name * lpad(string(i), 3) * "\n")
            end
            write(io, "FTR  99\n")     # footer (skipped)
        end
        baseline = parse_file(path, schema;
                              skip_header=1, skip_footer=1, comment=UInt8('#'))
        for nt in (2, 4, 8)
            r = parse_file(path, schema;
                          skip_header=1, skip_footer=1, comment=UInt8('#'), ntasks=nt)
            @test r.val == baseline.val
            @test r.name == baseline.name
        end
        rm(path)
    end

    @testset ":default mode with ntasks=$nt" for nt in (1, 2, 4, 8)
        schema = FixedWidthSchema(
            :name => (4, FWString(; default="")),
            :val  => (3, FWInt(; default=0)),
        )
        path = tempname()
        open(path, "w") do io
            for i in 1:400
                name = i % 7 == 0 ? "    " : lpad("r$i", 4)[1:4]   # blank every 7th
                val  = i % 5 == 0 ? "   "  : lpad(string(i), 3)    # blank every 5th
                write(io, name * val * "\n")
            end
        end
        r = parse_file(path, schema; on_error=:default, ntasks=nt)
        @test length(r) == 400
        for i in 1:400
            @test r.name[i] == (i % 7 == 0 ? "" : lpad("r$i", 4)[1:4])
            @test r.val[i]  == (i % 5 == 0 ? 0  : i)
        end
        rm(path)
    end

    @testset "strict ParseError pinpoints failing line with ntasks=$nt" for nt in (2, 4, 8)
        # Under the new row-chunk shape, errors from any task must still
        # surface the exact record index that failed, not just "some task
        # threw". The outer rescan+throw logic in _fill_column_strict! is
        # responsible.
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = tempname()
        open(path, "w") do io
            for i in 1:50;  write(io, "aaa " * lpad(string(i), 3) * "\n"); end
            write(io, "bad  XY\n")       # line 51 — bad int
            for i in 52:100; write(io, "ccc " * lpad(string(i), 3) * "\n"); end
        end
        err = try
            parse_file(path, schema; ntasks=nt); nothing
        catch e
            e
        end
        @test err isa ParseError
        @test err.line == 51
        rm(path)
    end
end
