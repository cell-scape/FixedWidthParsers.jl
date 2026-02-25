using Test
using FixedWidthParsers
using FixedWidthParsers: _valid_record_indices, MmapSource

@testset "Record Skipping" begin
    @testset "_valid_record_indices" begin
        function make_test_file(lines::Vector{String})
            path = tempname()
            open(path, "w") do io
                for line in lines
                    write(io, line * "\n")
                end
            end
            return path
        end

        @testset "no filtering returns nothing" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 0, 0, nothing) === nothing
            close(src)
            rm(path)
        end

        @testset "skip_header only" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC", "DDDD"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 2, 0, nothing) == [3, 4]
            close(src)
            rm(path)
        end

        @testset "skip_footer only" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC", "DDDD"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 0, 1, nothing) == [1, 2, 3]
            close(src)
            rm(path)
        end

        @testset "skip_header + skip_footer" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC", "DDDD"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 1, 1, nothing) == [2, 3]
            close(src)
            rm(path)
        end

        @testset "comment filtering" begin
            path = make_test_file(["#HDR", "AAAA", "#CMT", "BBBB"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 0, 0, UInt8('#')) == [2, 4]
            close(src)
            rm(path)
        end

        @testset "all three combined" begin
            path = make_test_file(["#HDR", "HDR2", "AAAA", "#CMT", "BBBB", "FTR1"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 1, 1, UInt8('#')) == [2, 3, 5]
            close(src)
            rm(path)
        end

        @testset "skip everything returns empty" begin
            path = make_test_file(["AAAA", "BBBB"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 2, 0, nothing) == Int[]
            @test _valid_record_indices(src, 0, 2, nothing) == Int[]
            @test _valid_record_indices(src, 1, 1, nothing) == Int[]
            @test _valid_record_indices(src, 10, 10, nothing) == Int[]
            close(src)
            rm(path)
        end
    end

    @testset "parse_file with skip_header" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")  # header line (same width=7)
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end

        result = parse_file(path, schema; skip_header=1)
        @test length(result) == 3
        @test result.name == ["foo", "bar", "baz"]
        @test result.val == [10, 20, 30]
        rm(path)
    end

    @testset "parse_file with skip_footer" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        result = parse_file(path, schema; skip_footer=1)
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test result.val == [10, 20]
        rm(path)
    end

    @testset "parse_file with comment" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "#cmt 00\n")
            write(io, "baz  30\n")
        end

        result = parse_file(path, schema; comment=UInt8('#'))
        @test length(result) == 3
        @test result.name == ["foo", "bar", "baz"]
        @test result.val == [10, 20, 30]
        rm(path)
    end

    @testset "parse_file with all three" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        result = parse_file(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test result.val == [10, 20]
        rm(path)
    end

    @testset "skip all records returns empty" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
        end

        result = parse_file(path, schema; skip_header=2)
        @test length(result) == 0

        result = parse_file(path, schema; skip_footer=2)
        @test length(result) == 0

        result = parse_file(path, schema; skip_header=1, skip_footer=1)
        @test length(result) == 0

        result = parse_file(path, schema; skip_header=100)
        @test length(result) == 0

        rm(path)
    end

    @testset "row-oriented with skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        result = parse_file(path, schema; columnar=false, skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(result) == 2
        @test result[1].name == "foo"
        @test result[1].val == 10
        @test result[2].name == "bar"
        @test result[2].val == 20
        rm(path)
    end

    @testset "parallel + skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            for i in 1:100
                if i % 10 == 0
                    write(io, "#cmt 00\n")
                else
                    write(io, lpad("r$i", 4)[1:4] * lpad(string(i), 3) * "\n")
                end
            end
            write(io, "FTR  --\n")
        end

        baseline = parse_file(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#'), ntasks=1)
        for nt in [2, 4]
            result = parse_file(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#'), ntasks=nt)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end
        rm(path)
    end

    @testset "eachrecord with skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        records = collect(eachrecord(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#')))
        @test length(records) == 2
        @test records[1].name == "foo"
        @test records[1].val == 10
        @test records[2].name == "bar"
        @test records[2].val == 20
        rm(path)
    end

    @testset "eachrecord with IO and skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        data = "HDR  --\nfoo  10\n#cmt 00\nbar  20\n"
        io = IOBuffer(data)

        records = collect(eachrecord(io, schema; skip_header=1, comment=UInt8('#')))
        @test length(records) == 2
        @test records[1].name == "foo"
        @test records[2].name == "bar"
    end

    @testset "no-op defaults match unfiltered" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end

        baseline = parse_file(path, schema)
        result = parse_file(path, schema; skip_header=0, skip_footer=0, comment=nothing)
        @test result.name == baseline.name
        @test result.val == baseline.val
        rm(path)
    end

    @testset "@fixedwidth struct with skipping" begin
        @fixedwidth struct SkipTestRecord
            name::String = 4
            val::Int     = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        result = parse_file(path, SkipTestRecord; skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test result.val == [10, 20]

        # Also test eachrecord with @fixedwidth (already handled by Task 4 dispatch)
        records = collect(eachrecord(path, SkipTestRecord; skip_header=1, skip_footer=1, comment=UInt8('#')))
        @test length(records) == 2

        rm(path)
    end
end
